//! 会话编排：快捷键 → 录音 → 识别 → 上屏；「全部」模式流式候选面板；设置页渠道对比
use crate::hotkey::{HotEvent, Shared};
use crate::settings::{Channel, Settings};
use crate::{offline, ui, wtoffline, AppState};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tauri::async_runtime::JoinHandle;
use voicekey_core::audio::Recorder;
use voicekey_core::{BaiduEngine, DoubaoEngine, Engine, IflyEngine, QwenEngine, SogouEngine, WeTypeEngine};
use voicekey_platform::{self as pf, Special, Typer};

pub enum Msg {
    Hot(HotEvent),
    Level(f32),
    Partial { gen: u64, ch: Channel, text: String },
    Done { gen: u64, ch: Channel, res: Result<String, String> },
    Timeout { token: u64 },
    Flush,
    PickChoose(usize),
    PickKey(Special),
    CompareToggle,
    CompareStop,
    Meter(bool),
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Debug)]
#[serde(rename_all = "lowercase")]
pub enum RowState {
    Listen,
    Wait,
    Final,
    Error,
    Skip,
}

#[derive(Clone, Serialize)]
pub struct Row {
    channel: Channel,
    text: String,
    state: RowState,
    ms: Option<u64>,
}

#[derive(Clone, Serialize)]
struct Model<'a> {
    recording: bool,
    rows: &'a [Row],
    sel: usize,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    Idle,
    Single(Channel),
    Pick,
    Compare,
}

pub struct Ctl {
    app: AppHandle,
    settings: Arc<RwLock<Settings>>,
    hk: Arc<Shared>,
    tx: UnboundedSender<Msg>,
    engines: HashMap<Channel, Arc<dyn Engine>>,
    recorder: Option<Recorder>,
    meter: Option<Recorder>,
    tasks: Vec<JoinHandle<()>>,
    gen: u64,
    timeout_token: u64,
    mode: Mode,
    recording: bool,
    auto_stop: bool,
    heard_voice: bool,
    last_voice: Instant,
    typer: Option<Typer>,
    rows: Vec<Row>,
    sel: usize,
    user_picked: bool,
    released_at: Option<Instant>,
    front: Option<pf::FrontApp>,
    last_emit: Instant,
    flush_pending: bool,
}

pub fn spawn(app: AppHandle, qwen: Arc<QwenEngine>, rx: UnboundedReceiver<Msg>) {
    let st = app.state::<AppState>();
    let mut engines: HashMap<Channel, Arc<dyn Engine>> = HashMap::new();
    engines.insert(Channel::Doubao, Arc::new(DoubaoEngine));
    engines.insert(Channel::Wetype, Arc::new(WeTypeEngine::default()));
    engines.insert(Channel::Qwen, qwen);
    engines.insert(Channel::Baidu, Arc::new(BaiduEngine));
    engines.insert(Channel::Sogou, Arc::new(SogouEngine));
    engines.insert(Channel::Iflytek, Arc::new(IflyEngine));
    if let Some(e) = offline::engine() {
        engines.insert(Channel::Offline, e);
    }
    engines.insert(Channel::WetypeOffline, wtoffline::engine());
    let ctl = Ctl {
        settings: st.settings.clone(),
        hk: st.hk.clone(),
        tx: st.tx.clone(),
        app: app.clone(),
        engines,
        recorder: None,
        meter: None,
        tasks: Vec::new(),
        gen: 0,
        timeout_token: 0,
        mode: Mode::Idle,
        recording: false,
        auto_stop: false,
        heard_voice: false,
        last_voice: Instant::now(),
        typer: None,
        rows: Vec::new(),
        sel: 0,
        user_picked: false,
        released_at: None,
        front: None,
        last_emit: Instant::now(),
        flush_pending: false,
    };
    tauri::async_runtime::spawn(ctl.run(rx));
}

impl Ctl {
    async fn run(mut self, mut rx: UnboundedReceiver<Msg>) {
        while let Some(m) = rx.recv().await {
            self.handle(m);
        }
    }

    fn settings(&self) -> Settings {
        self.settings.read().unwrap().clone()
    }

    fn handle(&mut self, m: Msg) {
        match m {
            Msg::Hot(e) => self.hot(e),
            Msg::Level(v) => {
                let _ = self.app.emit("level", v);
                self.check_silence(v);
            }
            Msg::Partial { gen, ch, text } if gen == self.gen => self.partial(ch, text),
            Msg::Done { gen, ch, res } if gen == self.gen => self.done(ch, res),
            Msg::Timeout { token } if token == self.timeout_token && self.mode != Mode::Idle => {
                self.abort(Some("识别超时".into()))
            }
            Msg::Flush => {
                self.flush_pending = false;
                self.emit_rows();
            }
            Msg::PickChoose(i) if self.mode == Mode::Pick => self.choose(i),
            Msg::PickKey(k) if self.mode == Mode::Pick => self.pick_key(k),
            Msg::CompareToggle => match self.mode {
                Mode::Compare if self.recording => self.end(),
                Mode::Idle => self.begin_multi(Mode::Compare, Channel::engines(), false),
                _ => {}
            },
            Msg::CompareStop if self.mode == Mode::Compare => self.abort(None),
            Msg::Meter(on) => {
                self.meter = None;
                if on && self.mode == Mode::Idle {
                    let tx = self.tx.clone();
                    let mic = self.settings().mic;
                    self.meter = Recorder::start(Some(&mic), move |v| {
                        let _ = tx.send(Msg::Level(v));
                    })
                    .ok()
                    .map(|(r, _)| r);
                }
            }
            _ => {}
        }
    }

    fn hot(&mut self, e: HotEvent) {
        match e {
            HotEvent::Press => {
                if matches!(self.mode, Mode::Single(_) | Mode::Pick) && !self.recording {
                    return self.abort(None);
                }
                if self.mode == Mode::Idle {
                    self.prewarm();
                }
            }
            HotEvent::LongPress => self.begin(false),
            HotEvent::Release => {
                if !self.auto_stop && self.mode != Mode::Compare {
                    self.end()
                }
            }
            HotEvent::Tap => {
                if self.mode == Mode::Compare {
                    return;
                }
                if self.recording {
                    self.end()
                } else if self.mode != Mode::Idle {
                    self.abort(None)
                } else {
                    self.begin(true)
                }
            }
            HotEvent::Escape => {
                if matches!(self.mode, Mode::Single(_) | Mode::Pick) {
                    self.abort(None)
                }
            }
            HotEvent::Pick(k) if self.mode == Mode::Pick => self.pick_key(k),
            HotEvent::Pick(_) => {}
            HotEvent::Recorded(sc) => {
                let _ = self.app.emit_to("main", "recorded", sc.clone());
                if let Some(sc) = sc {
                    crate::update_settings(&self.app, |s| s.tap_shortcut = Some(sc));
                }
            }
        }
    }

    fn prewarm(&self) {
        let ch = self.settings().channel;
        let list = if ch == Channel::All { self.settings().multi } else { vec![ch] };
        for c in list {
            if let Some(e) = self.engines.get(&c).cloned() {
                tauri::async_runtime::spawn(async move { e.prewarm().await });
            }
        }
    }

    fn start_recorder(&mut self) -> Option<voicekey_core::Audio> {
        self.meter = None;
        let tx = self.tx.clone();
        let mic = self.settings().mic;
        match Recorder::start(Some(&mic), move |v| {
            let _ = tx.send(Msg::Level(v));
        }) {
            Ok((r, audio)) => {
                self.recorder = Some(r);
                self.recording = true;
                self.heard_voice = false;
                self.last_voice = Instant::now();
                ui::set_tray_active(&self.app, true);
                Some(audio)
            }
            Err(e) => {
                ui::hud_error(&self.app, &format!("{e:#}"));
                None
            }
        }
    }

    fn stop_recording(&mut self) {
        if !self.recording {
            return;
        }
        self.recording = false;
        self.auto_stop = false;
        if let Some(mut r) = self.recorder.take() {
            r.stop();
        }
        ui::set_tray_active(&self.app, false);
    }

    fn spawn_engine(&mut self, ch: Channel, audio: voicekey_core::Audio) {
        let Some(engine) = self.engines.get(&ch).cloned() else { return };
        let (gen, tx) = (self.gen, self.tx.clone());
        self.tasks.push(tauri::async_runtime::spawn(async move {
            let ptx = tx.clone();
            let partial = Box::new(move |t: &str| {
                let _ = ptx.send(Msg::Partial { gen, ch, text: t.to_string() });
            });
            let res = engine.run(audio, partial).await.map_err(|e| format!("{e:#}"));
            let _ = tx.send(Msg::Done { gen, ch, res });
        }));
    }

    fn begin(&mut self, auto_stop: bool) {
        if self.mode != Mode::Idle {
            return;
        }
        let s = self.settings();
        if s.channel == Channel::All {
            return self.begin_multi(Mode::Pick, s.multi, auto_stop);
        }
        let Some(audio) = self.start_recorder() else { return };
        self.auto_stop = auto_stop;
        self.gen += 1;
        self.mode = Mode::Single(s.channel);
        self.typer = s.streaming.then(Typer::default);
        ui::hud(&self.app, "listen", "", s.channel);
        self.spawn_engine(s.channel, audio);
    }

    fn begin_multi(&mut self, mode: Mode, channels: Vec<Channel>, auto_stop: bool) {
        let Some(mut audio) = self.start_recorder() else { return };
        self.auto_stop = auto_stop;
        self.gen += 1;
        self.mode = mode;
        self.sel = 0;
        self.user_picked = false;
        self.released_at = None;
        self.rows = channels
            .into_iter()
            .map(|ch| {
                let skip = !crate::model_ready(ch);
                Row {
                    channel: ch,
                    text: if skip { "离线模型未下载，已跳过".into() } else { String::new() },
                    state: if skip { RowState::Skip } else { RowState::Listen },
                    ms: None,
                }
            })
            .collect();
        let active: Vec<Channel> = self.rows.iter().filter(|r| r.state == RowState::Listen).map(|r| r.channel).collect();
        let mut senders = Vec::new();
        for ch in active {
            let (t, r) = mpsc::unbounded_channel();
            senders.push(t);
            self.spawn_engine(ch, r);
        }
        self.tasks.push(tauri::async_runtime::spawn(async move {
            while let Some(f) = audio.recv().await {
                for s in &senders {
                    let _ = s.send(f.clone());
                }
            }
        }));
        if mode == Mode::Pick {
            let last = self.settings().last_pick;
            if let Some(i) = self.rows.iter().position(|r| Some(r.channel) == last && r.state == RowState::Listen) {
                self.sel = i;
                self.user_picked = true;
            }
            self.front = pf::front_app();
            self.hk.picking.store(true, Ordering::Relaxed);
            // 安全输入下钩子收不到方向键/数字：改为让面板取得焦点自己接收按键
            ui::pick_show(&self.app, pf::caret(), self.rows.len(), pf::secure_input());
        }
        self.emit_rows();
    }

    fn partial(&mut self, ch: Channel, text: String) {
        match self.mode {
            Mode::Single(_) => {
                if let Some(t) = self.typer.as_mut() {
                    t.update(&text);
                }
                let shown = if self.settings.read().unwrap().live_text { text.as_str() } else { "" };
                ui::hud(&self.app, if self.recording { "listen" } else { "wait" }, shown, ch);
            }
            Mode::Pick | Mode::Compare => {
                if let Some(r) = self.rows.iter_mut().find(|r| r.channel == ch) {
                    if matches!(r.state, RowState::Listen | RowState::Wait) {
                        r.text = text;
                    }
                }
                self.emit_rows();
            }
            Mode::Idle => {}
        }
    }

    fn done(&mut self, ch: Channel, res: Result<String, String>) {
        match self.mode {
            Mode::Single(_) => {
                self.stop_recording();
                self.timeout_token += 1;
                self.tasks.clear();
                self.mode = Mode::Idle;
                let typer = self.typer.take();
                match res {
                    Ok(text) => {
                        if let Some(mut t) = typer {
                            // 定稿可能与流式结果不同（数字/标点整理），按差异修正；之后到达的迟到片段丢弃
                            if !text.is_empty() {
                                t.update(&text);
                            }
                            t.finish();
                            ui::hud_hide(&self.app, 0);
                        } else if text.is_empty() {
                            ui::hud(&self.app, "info", "没有识别到内容", ch);
                            ui::hud_hide(&self.app, 1000);
                        } else {
                            ui::hud_hide(&self.app, 0);
                            pf::paste(&text);
                        }
                    }
                    Err(e) => ui::hud_error(&self.app, &format!("识别失败：{e}")),
                }
            }
            Mode::Pick | Mode::Compare => {
                let ms = self.released_at.map(|t| t.elapsed().as_millis() as u64);
                let Some(i) = self.rows.iter().position(|r| r.channel == ch) else { return };
                let r = &mut self.rows[i];
                match res {
                    Ok(t) if !t.is_empty() => {
                        r.text = t;
                        r.state = RowState::Final;
                        r.ms = Some(ms.unwrap_or(0));
                    }
                    Ok(_) => {
                        r.text = "没有识别到内容".into();
                        r.state = RowState::Error;
                    }
                    Err(e) => {
                        r.text = e;
                        r.state = RowState::Error;
                    }
                }
                let cur = self.rows[self.sel].state;
                let fallback = !self.user_picked || matches!(cur, RowState::Error | RowState::Skip);
                if self.rows[i].state == RowState::Final && fallback && cur != RowState::Final {
                    self.sel = i;
                }
                let finished = !self.rows.iter().any(|r| matches!(r.state, RowState::Listen | RowState::Wait));
                if finished {
                    self.timeout_token += 1;
                    if self.mode == Mode::Compare {
                        self.stop_recording();
                        self.mode = Mode::Idle;
                        self.tasks.clear();
                    }
                }
                self.emit_rows();
            }
            Mode::Idle => {}
        }
    }

    /// 说过话后静音超过设定时长即结束；一直没开口则 8 秒后放弃
    fn check_silence(&mut self, level: f32) {
        if !self.recording || !self.auto_stop {
            return;
        }
        if level > 0.3 {
            self.heard_voice = true;
            self.last_voice = Instant::now();
        } else {
            let limit = if self.heard_voice { self.settings().silence } else { 8.0 };
            if self.last_voice.elapsed().as_secs_f64() > limit {
                self.end();
            }
        }
    }

    fn end(&mut self) {
        if !self.recording {
            return;
        }
        self.stop_recording();
        match self.mode {
            Mode::Single(ch) => ui::hud(&self.app, "wait", "", ch),
            Mode::Pick | Mode::Compare => {
                self.released_at = Some(Instant::now());
                for r in &mut self.rows {
                    if r.state == RowState::Listen {
                        r.state = RowState::Wait;
                    }
                }
                self.emit_rows();
            }
            Mode::Idle => return,
        }
        self.timeout_token += 1;
        let (token, tx) = (self.timeout_token, self.tx.clone());
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_secs(15)).await;
            let _ = tx.send(Msg::Timeout { token });
        });
    }

    /// 打断：再按快捷键/Esc/超时；message 为 None 表示用户取消
    fn abort(&mut self, message: Option<String>) {
        if self.mode == Mode::Idle {
            return;
        }
        let mode = self.mode;
        self.cancel();
        if mode == Mode::Pick {
            if let Some(f) = self.front.take() {
                f.activate();
            }
        }
        if mode == Mode::Compare {
            for r in &mut self.rows {
                if matches!(r.state, RowState::Listen | RowState::Wait) {
                    r.state = RowState::Error;
                    r.text = message.clone().unwrap_or_else(|| "已取消".into());
                }
            }
            self.emit_rows();
            return;
        }
        match message {
            Some(m) => ui::hud_error(&self.app, &m),
            None => ui::hud_hide(&self.app, 0),
        }
    }

    fn cancel(&mut self) {
        self.gen += 1;
        self.timeout_token += 1;
        for t in self.tasks.drain(..) {
            t.abort();
        }
        self.stop_recording();
        if let Some(mut t) = self.typer.take() {
            t.finish();
        }
        if self.mode == Mode::Pick {
            self.hk.picking.store(false, Ordering::Relaxed);
            ui::pick_hide(&self.app);
        }
        self.mode = Mode::Idle;
    }

    fn pick_key(&mut self, k: Special) {
        let n = self.rows.len();
        if n == 0 {
            return;
        }
        match k {
            Special::Up | Special::Down => {
                self.sel = if k == Special::Down { (self.sel + 1) % n } else { (self.sel + n - 1) % n };
                self.user_picked = true;
                self.emit_rows();
            }
            Special::Digit(d) => {
                let i = d as usize - 1;
                if i >= n {
                    return;
                }
                if self.sel == i {
                    self.choose(i);
                } else {
                    self.sel = i;
                    self.user_picked = true;
                    self.emit_rows();
                }
            }
            Special::Enter => self.choose(self.sel),
            Special::Escape => self.abort(None),
        }
    }

    /// 选中一行上屏；未定稿的行抖动提示
    fn choose(&mut self, i: usize) {
        let Some(r) = self.rows.get(i) else { return };
        if r.state != RowState::Final {
            self.sel = i;
            self.user_picked = true;
            self.emit_rows();
            let _ = self.app.emit_to("pick", "pick-shake", i);
            return;
        }
        let text = r.text.clone();
        let ch = r.channel;
        if self.settings().last_pick != Some(ch) {
            crate::update_settings(&self.app, |s| s.last_pick = Some(ch));
        }
        let front = self.front.take();
        self.cancel();
        tauri::async_runtime::spawn(async move {
            if let Some(f) = front {
                f.activate();
            }
            tokio::time::sleep(Duration::from_millis(80)).await;
            pf::paste(&text);
        });
    }

    /// 最多每 33ms 推送一次，避免文字跳动
    fn emit_rows(&mut self) {
        let wait = Duration::from_millis(33).saturating_sub(self.last_emit.elapsed());
        if !wait.is_zero() {
            if !self.flush_pending {
                self.flush_pending = true;
                let tx = self.tx.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(wait).await;
                    let _ = tx.send(Msg::Flush);
                });
            }
            return;
        }
        self.last_emit = Instant::now();
        let model = Model { recording: self.recording, rows: &self.rows, sel: self.sel };
        match self.mode {
            Mode::Pick => {
                let _ = self.app.emit_to("pick", "pick", model);
            }
            _ => {
                let _ = self.app.emit_to("main", "compare", model);
            }
        }
    }
}
