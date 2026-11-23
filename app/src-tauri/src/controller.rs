//! 会话编排：快捷键 → 录音 → 识别 → 上屏；「全部」模式流式候选面板；设置页渠道对比
use crate::hotkey::{HotEvent, Shared};
use crate::settings::{Channel, Settings};
use crate::sound::SoundEvent;
use crate::{offline, ui, wtoffline, AppState};
use serde::Serialize;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tauri::async_runtime::JoinHandle;
use voicekey_core::audio::Recorder;
use voicekey_core::jev::{Config as JevConfig, SelectionThreshold};
use voicekey_core::{BageshuoEngine, BaiduEngine, ChatterflyEngine, DoubaoEngine, Engine, IflyEngine, QwenAppEngine, QwenEngine, SogouEngine, WeTypeEngine};
use voicekey_platform::{self as pf, Special, Typer};

pub enum Msg {
    Hot(HotEvent),
    Level(f32),
    Partial { gen: u64, ch: Channel, seg: usize, text: String },
    Done { gen: u64, ch: Channel, seg: usize, res: Result<String, String> },
    Timeout { token: u64 },
    PickGrace { gen: u64, token: u64 },
    Flush,
    PickChoose(usize),
    PickChooseFinal,
    PickKey(Special),
    CompareToggle,
    CompareStop,
    Meter(bool),
    RefreshMeter,
    /// 设置页在录音中即时调整 ducking；worker 自己负责所有权判断、平滑重定向和安全恢复。
    VolumeDucking { enabled: bool, reduction_percent: u8 },
    MicrophonesChanged(Vec<String>),
    /// Jev 评选结果：res 是 rows 下标；gen 与 token 任一对不上都说明已过期
    JevDone { gen: u64, token: u64, res: Result<usize, String> },
    /// LLM 流式融合增量文本
    LlmDelta { gen: u64, token: u64, text: String },
    /// LLM 融合定稿完成
    LlmDone { gen: u64, token: u64, res: Result<voicekey_core::llm::FuseResult, String> },
}

/// 候选框里 LLM 融合定稿行的状态
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Debug)]
#[serde(rename_all = "lowercase")]
pub enum LlmState {
    Idle,
    Busy,
    Ready,
    Skipped,
    Failed,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FinalizedRow {
    state: LlmState,
    text: String,
    ms: Option<u64>,
    note: Option<String>,
    source_channel: Option<Channel>,
}

impl FinalizedRow {
    fn idle() -> Self {
        Self { state: LlmState::Idle, text: String::new(), ms: None, note: None, source_channel: None }
    }
}

/// 在途 LLM 请求：token 丢弃晚到消息，task 用来真正中止连接（手选、取消、续录时不再继续计费）
#[derive(Default)]
struct LlmJob {
    token: u64,
    task: Option<JoinHandle<()>>,
}

impl LlmJob {
    fn start(&mut self, spawn: impl FnOnce(u64) -> JoinHandle<()>) {
        self.stop();
        self.task = Some(spawn(self.token));
    }

    fn stop(&mut self) {
        self.token += 1;
        if let Some(t) = self.task.take() {
            t.abort();
        }
    }

    fn is_current(&self, token: u64) -> bool {
        token == self.token
    }
}

#[derive(Debug, PartialEq)]
enum LlmNext {
    InsertFinal,
    FocusFinal,
    InsertRow(usize),
    FocusRow(usize),
    Nothing,
}

/// LLM 结束后的定稿行与去向。失败或超时回退到当前选中的原始定稿（不是定稿就取第一条），用户不会什么都拿不到
fn llm_finish(res: Result<voicekey_core::llm::FuseResult, String>, rows: &[Row], sel: usize, auto_insert: bool) -> (FinalizedRow, LlmNext) {
    match res {
        Ok(out) => {
            let note = match &out.usage {
                Some(u) => format!("{} · {} tok", out.model, u.total_tokens),
                None => out.model.clone(),
            };
            let row = FinalizedRow { state: LlmState::Ready, text: out.text, ms: Some(out.ms), note: Some(note), source_channel: None };
            (row, if auto_insert { LlmNext::InsertFinal } else { LlmNext::FocusFinal })
        }
        Err(e) => {
            let is_final = |i: &usize| rows.get(*i).is_some_and(|r| r.state == RowState::Final);
            let fallback = Some(sel).filter(is_final).or_else(|| (0..rows.len()).find(is_final));
            let row = FinalizedRow {
                state: LlmState::Failed,
                text: e,
                ms: None,
                note: fallback.map(|i| format!("已回退到 {}", rows[i].channel.title())),
                source_channel: None,
            };
            let next = match fallback {
                Some(i) if auto_insert => LlmNext::InsertRow(i),
                Some(i) => LlmNext::FocusRow(i),
                None => LlmNext::Nothing,
            };
            (row, next)
        }
    }
}

/// 候选框里 Jev 智能选择的进度
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Debug)]
#[serde(rename_all = "lowercase")]
pub enum JevState {
    Idle,
    Busy,
    Failed,
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
    jev: JevState,
    finalized: Option<&'a FinalizedRow>,
    #[serde(rename = "selFinal")]
    sel_final: bool,
    history: Option<&'a HistoryView>,
}

/// 候选框上叠加的识别历史视图；打开时本轮候选与识别照常进行，关掉即回到候选
#[derive(Clone, Serialize)]
struct HistoryView {
    items: Vec<crate::history::HistoryEntry>,
    sel: usize,
    /// 识别历史是否开启；未开启时视图只提示，不影响本轮
    enabled: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum PickKey {
    /// 历史未打开：交给候选行处理
    Rows(Special),
    Opened,
    Stay,
    Closed,
    Choose(usize),
}

impl HistoryView {
    fn key(&mut self, k: Special) -> PickKey {
        let n = self.items.len();
        match k {
            Special::Tab | Special::Escape => PickKey::Closed,
            _ if n == 0 => PickKey::Stay,
            Special::Up => {
                self.sel = (self.sel + n - 1) % n;
                PickKey::Stay
            }
            Special::Down => {
                self.sel = (self.sel + 1) % n;
                PickKey::Stay
            }
            Special::Digit(d) => {
                let i = d as usize - 1;
                if i < n && self.sel == i {
                    return PickKey::Choose(i);
                }
                if i < n {
                    self.sel = i;
                }
                PickKey::Stay
            }
            Special::Enter => PickKey::Choose(self.sel),
        }
    }
}

/// 候选框按键分流：Tab 打开/关闭历史视图，打开期间其余按键归历史；本轮候选不经过这里，不会被改动
fn route_pick_key(history: &mut Option<HistoryView>, k: Special, open: impl FnOnce() -> HistoryView) -> PickKey {
    match history {
        Some(h) => {
            let r = h.key(k);
            if r == PickKey::Closed {
                *history = None;
            }
            r
        }
        None if k == Special::Tab => {
            *history = Some(open());
            PickKey::Opened
        }
        None => PickKey::Rows(k),
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    Idle,
    Single(Channel),
    Pick,
    Compare,
}

/// 单渠道会话的分段：识别中再触发继续说，各段结果按顺序拼成一句
#[derive(Default)]
struct Segments {
    parts: Vec<(String, bool)>,
    error: Option<String>,
}

/// 候选等待独立于识别总超时；每次开始或续录快照选择参数并使旧定时器失效。
///
/// Candidate waiting is independent of recognition timeout. Starting or resuming snapshots selection settings and invalidates old timers.
struct PickProgress {
    grace: Option<Instant>,
    token: u64,
    threshold: SelectionThreshold,
    wait: Duration,
}

impl Default for PickProgress {
    fn default() -> Self {
        Self {
            grace: None, token: 0, threshold: SelectionThreshold::default(),
            wait: Duration::from_millis(voicekey_core::jev::SELECTION_WAIT_DEFAULT_MS),
        }
    }
}

impl PickProgress {
    fn begin(&mut self, mut config: JevConfig) {
        self.reset();
        config.sanitize_selection();
        self.threshold = config.selection_threshold;
        self.wait = Duration::from_millis(config.selection_wait_ms);
    }

    fn reset(&mut self) {
        self.cancel_grace();
    }

    fn cancel_grace(&mut self) {
        self.token += 1;
        self.grace = None;
    }

    fn arm(&mut self, now: Instant) -> Option<u64> {
        if self.grace.is_some() {
            return None;
        }
        self.token += 1;
        self.grace = Some(now + self.wait);
        Some(self.token)
    }

    fn expired(&self, token: u64, now: Instant) -> bool {
        token == self.token && self.grace.is_some_and(|deadline| now >= deadline)
    }
}

impl Segments {
    fn start(&mut self) -> usize {
        self.parts.push((String::new(), false));
        self.parts.len() - 1
    }

    /// None：该段已定稿，丢弃；Some(changed)：文字是否有变化
    fn partial(&mut self, i: usize, text: String) -> Option<bool> {
        match self.parts.get_mut(i) {
            Some((t, false)) => {
                let changed = *t != text;
                *t = text;
                Some(changed)
            }
            _ => None,
        }
    }

    /// keep_partial：流式上屏时，定稿为空也保留已打出的片段。失败一律留下已显示的中间结果
    fn done(&mut self, i: usize, res: Result<String, String>, keep_partial: bool) {
        let Some((t, done)) = self.parts.get_mut(i) else { return };
        if *done {
            return;
        }
        *done = true;
        match res {
            Ok(s) if !s.is_empty() => *t = s,
            Ok(_) => {
                if !keep_partial {
                    t.clear()
                }
            }
            Err(e) => self.error = Some(e),
        }
    }

    fn finished(&self) -> bool {
        self.parts.iter().all(|p| p.1)
    }

    fn text(&self) -> String {
        self.parts.iter().map(|p| p.0.as_str()).collect()
    }
}

pub struct Ctl {
    app: AppHandle,
    settings: Arc<RwLock<Settings>>,
    hk: Arc<Shared>,
    tx: UnboundedSender<Msg>,
    engines: HashMap<Channel, Arc<dyn Engine>>,
    recorder: Option<Recorder>,
    meter: Option<Recorder>,
    meter_enabled: bool,
    volume_ducking: pf::OutputVolumeDucker,
    tasks: Vec<JoinHandle<()>>,
    gen: u64,
    timeout_token: u64,
    mode: Mode,
    recording: bool,
    auto_stop: bool,
    heard_voice: bool,
    last_voice: Instant,
    typer: Option<Typer>,
    segs: Segments,
    rows: Vec<Row>,
    row_segs: Vec<Segments>,
    sel: usize,
    user_picked: bool,
    choose_pending: bool,
    pick: PickProgress,
    jev: JevState,
    /// 当前有效的 Jev 请求编号；手选或新一段录音时自增，晚到结果据此丢弃
    jev_token: u64,
    /// 候选框顶部的「最终定稿」行（启用 LLM 融合定稿时存在）
    finalized: Option<FinalizedRow>,
    llm: LlmJob,
    /// 当前焦点是否在顶部的「最终定稿」行上
    sel_final: bool,
    /// 用户做过选择类操作。`user_picked` 会被 `last_pick` 预选置位，不能代替它
    manual: bool,
    released_at: Option<Instant>,
    front: Option<pf::FrontApp>,
    last_emit: Instant,
    flush_pending: bool,
    /// 本次录音结束时刻：「处理」提示音须在音量还原完成后播放，以此估算剩余还原窗口
    stopped_at: Option<Instant>,
    /// 本次会话是否确实压低过系统音量：「处理/失败」提示音只在压过音量时等待恢复窗口；
    /// ducking 关闭（默认）或未生效时识别结束后立即播放，不固定晚约 450ms
    ducked: bool,
    /// 提示音会话代数：每次开始录音递增；延迟提示音到期时代数已变则丢弃，
    /// 避免快速连续开始/停止时新旧提示音错拍重叠（发出奇怪声音）
    chime_gen: std::sync::Arc<std::sync::atomic::AtomicU64>,
    /// 按下到判定长按之间已经打开的麦克风，确认开始后把这段音频交出去
    primed: Option<Primed>,
    history: Option<HistoryView>,
}

/// 预开麦：先环形缓存，确认录音后转成实时帧流
struct Primed {
    recorder: Recorder,
    gate: Arc<Mutex<Gate>>,
}

enum Gate {
    Buffer(VecDeque<Vec<i16>>),
    Forward(UnboundedSender<Vec<i16>>),
}

const PREROLL: usize = 50;

pub fn spawn(app: AppHandle, qwen: Arc<QwenEngine>, rx: UnboundedReceiver<Msg>) {
    let st = app.state::<AppState>();
    let volume_fraction = st.settings.read().unwrap().retained_system_volume_fraction();
    let mut engines: HashMap<Channel, Arc<dyn Engine>> = HashMap::new();
    engines.insert(Channel::Doubao, Arc::new(DoubaoEngine));
    engines.insert(Channel::Wetype, Arc::new(WeTypeEngine::default()));
    engines.insert(Channel::Qwen, qwen);
    engines.insert(Channel::Baidu, Arc::new(BaiduEngine));
    engines.insert(Channel::Sogou, Arc::new(SogouEngine));
    engines.insert(Channel::Iflytek, Arc::new(IflyEngine));
    engines.insert(Channel::Chatterfly, Arc::new(ChatterflyEngine));
    engines.insert(Channel::QwenApp, Arc::new(QwenAppEngine::default()));
    engines.insert(Channel::Bageshuo, Arc::new(BageshuoEngine));
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
        meter_enabled: false,
        volume_ducking: pf::OutputVolumeDucker::new(volume_fraction),
        tasks: Vec::new(),
        gen: 0,
        timeout_token: 0,
        mode: Mode::Idle,
        recording: false,
        auto_stop: false,
        heard_voice: false,
        last_voice: Instant::now(),
        typer: None,
        segs: Segments::default(),
        rows: Vec::new(),
        row_segs: Vec::new(),
        sel: 0,
        user_picked: false,
        choose_pending: false,
        pick: PickProgress::default(),
        jev: JevState::Idle,
        jev_token: 0,
        finalized: None,
        llm: LlmJob::default(),
        sel_final: false,
        manual: false,
        released_at: None,
        front: None,
        last_emit: Instant::now(),
        flush_pending: false,
        stopped_at: None,
        ducked: false,
        chime_gen: std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
        primed: None,
        history: None,
    };
    tauri::async_runtime::spawn(ctl.run(rx));
}

/// 焦点能接收文字，且当前不是安全输入（密码框）。流式上屏、粘贴、候选框延迟上屏都走这一条件。
fn allow_text_input(has_text_target: bool, secure_input: bool) -> bool {
    has_text_target && !secure_input
}

const CLIPBOARD_HINT: &str = "没有可输入的位置，文字已复制到剪贴板";

/// 焦点可输入，或用户开启了「无输入位置时也强制上屏」，就走粘贴；否则只写剪贴板
fn should_paste(allowed: bool, force: bool) -> bool {
    allowed || force
}

/// 上屏前按设置去除标点；只用于真正写入焦点/剪贴板/历史的文字
fn output_text(strip: bool, text: String) -> String {
    if strip {
        voicekey_core::util::strip_punctuation(&text)
    } else {
        text
    }
}

/// 能输入（或开启强制上屏）就粘贴；否则只写剪贴板，并用和 insert() 相同的浮层提示。结果同时记入识别历史。
fn deliver_text(app: &AppHandle, text: &str, ch: Channel) -> bool {
    let strip = app.state::<AppState>().settings.read().unwrap().strip_punctuation;
    let text = &output_text(strip, text.to_owned());
    if text.is_empty() {
        return false;
    }
    let ok = paste_or_copy(app, text, ch);
    crate::history::record(app, text, ch, ok);
    ok
}

fn paste_or_copy(app: &AppHandle, text: &str, ch: Channel) -> bool {
    let force = app.state::<AppState>().settings.read().unwrap().force_paste_without_target;
    let ok = should_paste(allow_text_input(pf::has_text_target(), pf::secure_input()), force);
    if ok {
        pf::paste(text);
    } else {
        pf::copy(text);
        ui::hud(app, "info", CLIPBOARD_HINT, ch);
        ui::hud_hide(app, 2600);
    }
    ok
}

impl Ctl {
    async fn run(mut self, mut rx: UnboundedReceiver<Msg>) {
        let mut retry = tokio::time::interval(Duration::from_secs(2));
        loop {
            tokio::select! {
                m = rx.recv() => {
                    let Some(m) = m else { break };
                    let was_idle = self.mode == Mode::Idle;
                    self.handle(m);
                    if !was_idle && self.mode == Mode::Idle {
                        self.refresh_meter();
                    }
                }
                _ = retry.tick() => {
                    // 驱动可能先公布输入通道，稍后才允许打开；只重试用户正在看的电平表。
                    if self.meter_enabled && self.mode == Mode::Idle && self.meter.is_none() {
                        self.refresh_meter();
                    }
                }
            }
        }
    }

    fn settings(&self) -> Settings {
        self.settings.read().unwrap().clone()
    }

    fn output_text(&self, text: String) -> String {
        output_text(self.settings.read().unwrap().strip_punctuation, text)
    }

    fn handle(&mut self, m: Msg) {
        match m {
            Msg::Hot(e) => self.hot(e),
            Msg::Level(v) => {
                let _ = self.app.emit("level", v);
                self.check_silence(v);
            }
            Msg::Partial { gen, ch, seg, text } if gen == self.gen => self.partial(ch, seg, text),
            Msg::Done { gen, ch, seg, res } if gen == self.gen => self.done(ch, seg, res),
            Msg::Timeout { token } if token == self.timeout_token && self.mode != Mode::Idle => {
                if self.mode == Mode::Pick && self.rows.iter().any(|r| r.state == RowState::Final) {
                    self.advance_pick();
                } else if self.history.is_some() {
                    // 正在看历史：不关面板也不代为上屏，只把超时的行封存，返回候选后仍可见
                    self.finish_slow_rows();
                    self.emit_rows();
                } else {
                    self.abort(Some("识别超时".into()))
                }
            }
            Msg::PickGrace { gen, token } if gen == self.gen && self.mode == Mode::Pick && !self.recording && self.pick.expired(token, Instant::now()) => {
                self.pick.cancel_grace();
                if self.choose_pending || (!self.manual && (self.llm_active() || self.settings().jev.targets().is_ok())) {
                    self.finish_slow_rows();
                }
                self.advance_pick();
                if self.mode == Mode::Pick {
                    self.emit_rows();
                }
            }
            Msg::Flush => {
                self.flush_pending = false;
                self.emit_rows();
            }
            Msg::JevDone { gen, token, res } => self.jev_done(gen, token, res),
            Msg::LlmDelta { gen, token, text } => self.llm_delta(gen, token, text),
            Msg::LlmDone { gen, token, res } => self.llm_done(gen, token, res),
            Msg::PickChoose(i) if self.mode == Mode::Pick && self.history.is_some() => self.choose_history(i),
            Msg::PickChoose(i) if self.mode == Mode::Pick => {
                self.take_manual();
                self.sel_final = false;
                self.choose(i)
            }
            Msg::PickChooseFinal if self.mode == Mode::Pick => {
                self.choose_final()
            }
            Msg::PickKey(k) if self.mode == Mode::Pick => self.pick_key(k),
            Msg::CompareToggle => match self.mode {
                Mode::Compare if self.recording => self.end(),
                Mode::Idle => self.begin_multi(Mode::Compare, Channel::engines(), false),
                _ => {}
            },
            Msg::CompareStop if self.mode == Mode::Compare => self.abort(None),
            Msg::Meter(on) => {
                self.meter_enabled = on;
                self.refresh_meter();
            }
            Msg::RefreshMeter => self.refresh_meter(),
            Msg::VolumeDucking { enabled, reduction_percent } => {
                // 设置/UI 统一使用“降低比例”；worker 只接收最终保留比例，因此只在这里做一次补数换算。
                // ducked 记录本次会话是否真的压低过音量：生效置位，显式关闭即视为已发起恢复。
                if enabled && self.recording {
                    self.ducked = true;
                } else if !enabled {
                    self.ducked = false;
                }
                self.volume_ducking.configure(enabled && self.recording, 1.0 - reduction_percent as f32 / 100.0)
            }
            Msg::MicrophonesChanged(mics) => {
                let _ = self.app.emit("microphones", mics);
                self.refresh_meter();
            }
            _ => {}
        }
    }

    fn refresh_meter(&mut self) {
        if self.mode != Mode::Idle {
            return;
        }
        self.meter = None;
        let _ = self.app.emit("level", 0.0f32);
        if self.meter_enabled {
            let tx = self.tx.clone();
            let mic = self.settings().mic;
            self.meter = Recorder::start(Some(&mic), move |v| {
                let _ = tx.send(Msg::Level(v));
            })
            .ok()
            .map(|(r, _)| r);
        }
    }

    fn hot(&mut self, e: HotEvent) {
        match e {
            HotEvent::Press => {
                if !self.recording && self.mode == Mode::Idle {
                    self.prewarm();
                    self.arm();
                } else if !self.recording && matches!(self.mode, Mode::Single(_) | Mode::Pick) {
                    self.arm();
                }
            }
            HotEvent::Cancel => self.disarm(),
            HotEvent::LongPress => match self.mode {
                Mode::Single(_) | Mode::Pick => self.resume(false),
                _ => self.begin(false),
            },
            HotEvent::Release => {
                // 点按录音由静音/Tap 结束；同键被判为长按后的 Release 不应改写点按语义。
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
                } else if matches!(self.mode, Mode::Single(_) | Mode::Pick) {
                    self.resume(true)
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
            HotEvent::RecordedHold(c) => {
                let _ = self.app.emit_to("main", "recorded", c.is_some());
                if let Some(c) = c {
                    crate::update_settings(&self.app, |s| {
                        s.hold_key = crate::settings::CUSTOM_HOLD.into();
                        s.hold_combo = Some(c);
                    });
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
        let audio = if let Some(audio) = self.take_primed() {
            audio
        } else {
            let tx = self.tx.clone();
            let mic = self.settings().mic;
            let (r, audio) = match Recorder::start(Some(&mic), move |v| {
                let _ = tx.send(Msg::Level(v));
            }) {
                Ok(v) => v,
                Err(e) => {
                    ui::hud_error(&self.app, &format!("{e:#}"));
                    crate::sound::play(&self.app, SoundEvent::Error);
                    return None;
                }
            };
            self.recorder = Some(r);
            self.recording = true;
            self.heard_voice = false;
            self.last_voice = Instant::now();
            audio
        };

        // 成功开麦（含预开麦转正）发开始音。开始音必须在压低音量之前发
        // （cometix-dictation 同序：开麦 → 播开始音 → 压音量），否则音没播完就被压掉。
        // 新会话开始：递增提示音代数，上一会话尚在排队/等待的延迟提示音全部作废；
        // ducked 按本会话重新累计，上一会话压没压过音量与本会话无关
        self.chime_gen.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.ducked = false;
        crate::sound::play(&self.app, SoundEvent::Start);
        // Press 时的 arm() 只是预开麦，误触/短按取消都不应碰系统音量；只有确认真正进入聆听后才开始 duck。
        // 压低延迟到开始提示音播完（按 play_duration）；handler 以 enabled && self.recording 把关，
        // 提示音播放期间会话被取消时不会压低音量。
        let settings = self.settings();
        let delay = crate::sound::play_duration(&self.app, SoundEvent::Start, &self.settings());
        let (enabled, reduction_percent) = (settings.lower_system_volume, settings.lower_system_volume_percent);
        let tx = self.tx.clone();
        let chime_gen = self.chime_gen.clone();
        let my_gen = chime_gen.load(std::sync::atomic::Ordering::Relaxed);
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(delay).await;
            // 延迟压音量与延迟提示音共用会话代数门闩：等待期间取消或又开了新会话
            // （代数已变）则丢弃本条，避免上一次的延迟消息压到新一次的开始音（review #6）
            if chime_gen.load(std::sync::atomic::Ordering::Relaxed) != my_gen {
                return;
            }
            let _ = tx.send(Msg::VolumeDucking { enabled, reduction_percent });
        });
        Some(audio)
    }

    /// 快捷键按下即开麦。短按取消或被别的键打断时关掉
    fn arm(&mut self) {
        if self.primed.is_some() || self.recording {
            return;
        }
        self.meter = None;
        let tx = self.tx.clone();
        let mic = self.settings().mic;
        let Ok((recorder, mut audio)) = Recorder::start(Some(&mic), move |v| {
            let _ = tx.send(Msg::Level(v));
        }) else {
            if self.mode == Mode::Idle {
                self.refresh_meter();
            }
            return;
        };
        let gate = Arc::new(Mutex::new(Gate::Buffer(VecDeque::new())));
        let shared = gate.clone();
        tauri::async_runtime::spawn(async move {
            while let Some(frame) = audio.recv().await {
                let mut gate = shared.lock().unwrap();
                match &mut *gate {
                    Gate::Buffer(q) => {
                        q.push_back(frame);
                        while q.len() > PREROLL {
                            q.pop_front();
                        }
                    }
                    Gate::Forward(tx) => {
                        if tx.send(frame).is_err() {
                            break;
                        }
                    }
                }
            }
        });
        self.primed = Some(Primed { recorder, gate });
    }

    fn disarm(&mut self) {
        if self.recording {
            return;
        }
        self.primed = None;
        if self.mode == Mode::Idle {
            self.refresh_meter();
        }
    }

    fn take_primed(&mut self) -> Option<voicekey_core::Audio> {
        let primed = self.primed.take()?;
        let (tx, rx) = mpsc::unbounded_channel();
        {
            let mut gate = primed.gate.lock().unwrap();
            if let Gate::Buffer(q) = &mut *gate {
                for frame in q.drain(..) {
                    let _ = tx.send(frame);
                }
            }
            *gate = Gate::Forward(tx);
        }
        self.recorder = Some(primed.recorder);
        self.recording = true;
        self.heard_voice = false;
        self.last_voice = Instant::now();
        Some(rx)
    }

    fn stop_recording(&mut self) {
        if !self.recording {
            return;
        }
        self.recording = false;
        self.auto_stop = false;
        // 先发恢复意图；若此时还在淡入/淡出，worker 会从当前实际音量平滑反向，而不是排队跑完整段动画。
        self.volume_ducking.set_active(false);
        self.stopped_at = Some(Instant::now());
        if let Some(mut r) = self.recorder.take() {
            r.stop();
        }
    }

    /// 录音结束后的单音提示（处理音/失败音）：等系统输出音量恢复后再播，避免卡在还原淡入的前半段听不清。
    /// 带会话代数门闩：等待期间用户再次开始录音（代数递增）则丢弃本条，避免新旧提示音错拍重叠。
    /// 恢复窗口只对本次会话确实压低过音量的情况有意义；ducking 关闭/未生效时立即播放。
    fn play_after_restore(&self, event: SoundEvent) {
        let app = self.app.clone();
        let restore_wait = if self.ducked { self.restore_wait() } else { Duration::ZERO };
        let gen = self.chime_gen.clone();
        let my_gen = gen.load(std::sync::atomic::Ordering::Relaxed);
        tauri::async_runtime::spawn(async move {
            if !restore_wait.is_zero() {
                tokio::time::sleep(restore_wait).await;
            }
            if gen.load(std::sync::atomic::Ordering::Relaxed) != my_gen {
                return;
            }
            crate::sound::play(&app, event);
        });
    }

    /// 距本次录音结束的剩余还原等待：stop 后不足恢复窗口（450ms，音量 worker 淡入上界）的部分。
    fn restore_wait(&self) -> Duration {
        const RESTORE_WINDOW: Duration = Duration::from_millis(450);
        let since_stop = self.stopped_at.map_or(RESTORE_WINDOW, |t| t.elapsed());
        RESTORE_WINDOW.saturating_sub(since_stop)
    }

    fn spawn_engine(&mut self, ch: Channel, seg: usize, audio: voicekey_core::Audio) {
        let Some(engine) = self.engines.get(&ch).cloned() else { return };
        let (gen, tx) = (self.gen, self.tx.clone());
        self.tasks.push(tauri::async_runtime::spawn(async move {
            let ptx = tx.clone();
            let partial = Box::new(move |t: &str| {
                let _ = ptx.send(Msg::Partial { gen, ch, seg, text: t.to_string() });
            });
            let res = engine.run(audio, partial).await.map_err(|e| format!("{e:#}"));
            let _ = tx.send(Msg::Done { gen, ch, seg, res });
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
        // 没有可输入焦点，或安全输入（密码框）时不边说边打：退格和字符都会进到前台。结束时改走 deliver_text。
        self.typer = (s.streaming && allow_text_input(pf::has_text_target(), pf::secure_input())).then(Typer::default);
        self.segs = Segments::default();
        let seg = self.segs.start();
        ui::hud(&self.app, "listen", "", s.channel);
        self.spawn_engine(s.channel, seg, audio);
    }

    /// 识别中或候选框未关时再触发：新开一段录音，结果接在前面几段后面
    fn resume(&mut self, auto_stop: bool) {
        if self.recording || !matches!(self.mode, Mode::Single(_) | Mode::Pick) {
            return;
        }
        let Some(audio) = self.start_recorder() else { return };
        self.auto_stop = auto_stop;
        self.timeout_token += 1;
        if let Mode::Single(ch) = self.mode {
            let seg = self.segs.start();
            self.hud_single(ch);
            return self.spawn_engine(ch, seg, audio);
        }
        self.released_at = None;
        self.choose_pending = false;
        self.history = None;
        self.pick.begin(self.settings().jev);
        self.jev_token += 1;
        self.jev = JevState::Idle;
        self.llm.stop();
        self.sel_final = false;
        self.finalized = self.llm_active().then(FinalizedRow::idle);
        self.manual = false;
        let mut targets = Vec::new();
        for (r, segs) in self.rows.iter_mut().zip(&mut self.row_segs) {
            if r.state == RowState::Skip {
                continue;
            }
            targets.push((r.channel, segs.start()));
            r.state = RowState::Listen;
            r.text = segs.text();
        }
        self.fan_out(audio, targets);
        self.emit_rows();
    }

    fn hud_single(&self, ch: Channel) {
        let text = if self.settings.read().unwrap().live_text { self.segs.text() } else { String::new() };
        ui::hud(&self.app, if self.recording { "listen" } else { "wait" }, &text, ch);
    }

    fn begin_multi(&mut self, mode: Mode, mut channels: Vec<Channel>, auto_stop: bool) {
        let Some(audio) = self.start_recorder() else { return };
        if mode == Mode::Pick {
            let n = self.settings().pick_counts;
            channels.sort_by_key(|c| std::cmp::Reverse(n.get(c).copied().unwrap_or(0)));
        }
        self.auto_stop = auto_stop;
        self.gen += 1;
        self.mode = mode;
        self.sel = 0;
        self.user_picked = false;
        self.choose_pending = false;
        self.jev_token += 1;
        self.jev = JevState::Idle;
        self.llm.stop();
        self.sel_final = false;
        self.finalized = (mode == Mode::Pick && self.llm_active()).then(FinalizedRow::idle);
        self.manual = false;
        self.released_at = None;
        self.pick.begin(self.settings().jev);
        self.rows = channels
            .into_iter()
            .map(|ch| {
                let skip = crate::unavailable(ch);
                Row {
                    channel: ch,
                    text: skip.unwrap_or_default().into(),
                    state: if skip.is_some() { RowState::Skip } else { RowState::Listen },
                    ms: None,
                }
            })
            .collect();
        self.row_segs = self.rows.iter().map(|_| Segments::default()).collect();
        let targets = self
            .rows
            .iter()
            .zip(&mut self.row_segs)
            .filter(|(r, _)| r.state == RowState::Listen)
            .map(|(r, segs)| (r.channel, segs.start()))
            .collect();
        self.fan_out(audio, targets);
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

    fn fan_out(&mut self, mut audio: voicekey_core::Audio, targets: Vec<(Channel, usize)>) {
        let mut senders = Vec::new();
        for (ch, seg) in targets {
            let (t, r) = mpsc::unbounded_channel();
            senders.push(t);
            self.spawn_engine(ch, seg, r);
        }
        self.tasks.push(tauri::async_runtime::spawn(async move {
            while let Some(f) = audio.recv().await {
                for s in &senders {
                    let _ = s.send(f.clone());
                }
            }
        }));
    }

    fn partial(&mut self, ch: Channel, seg: usize, text: String) {
        match self.mode {
            Mode::Single(_) => {
                let Some(changed) = self.segs.partial(seg, text) else { return };
                if changed {
                    self.speaking();
                }
                if self.typer.is_some() {
                    let text = self.output_text(self.segs.text());
                    if let Some(t) = self.typer.as_mut() {
                        t.update(&text);
                    }
                }
                self.hud_single(ch);
            }
            Mode::Pick | Mode::Compare => {
                if let Some(i) = self.rows.iter().position(|r| r.channel == ch) {
                    if self.mode == Mode::Pick && !matches!(self.rows[i].state, RowState::Listen | RowState::Wait) {
                        return;
                    }
                    if let Some(changed) = self.row_segs[i].partial(seg, text) {
                        self.rows[i].text = self.row_segs[i].text();
                        if changed {
                            self.speaking();
                        }
                    }
                }
                self.emit_rows();
            }
            Mode::Idle => {}
        }
    }

    /// 上屏：焦点接受文本就粘贴；没有输入框（或安全输入）时只写剪贴板并提示，避免整段文字丢失
    fn insert(&self, text: &str, ch: Channel) -> bool {
        deliver_text(&self.app, text, ch)
    }

    fn done(&mut self, ch: Channel, seg: usize, res: Result<String, String>) {
        match self.mode {
            Mode::Single(_) => {
                self.segs.done(seg, res, self.typer.is_some());
                let text = self.segs.text();
                let shown = self.output_text(text.clone());
                if !self.segs.finished() {
                    if let Some(t) = self.typer.as_mut().filter(|_| !text.is_empty()) {
                        t.update(&shown);
                    }
                    return;
                }
                self.stop_recording();
                self.timeout_token += 1;
                self.tasks.clear();
                self.mode = Mode::Idle;
                let typer = self.typer.take();
                let error = self.segs.error.take();
                let streamed = typer.is_some();
                if let Some(mut t) = typer {
                    // 定稿可能与流式结果不同（数字/标点整理），按差异修正；之后到达的迟到片段丢弃
                    if !text.is_empty() {
                        t.update(&shown);
                    }
                    t.finish();
                    crate::history::record(&self.app, &shown, ch, true);
                }
                if let Some(e) = error {
                    if !streamed && !text.is_empty() {
                        self.insert(&text, ch);
                    }
                    let msg = if text.is_empty() {
                        format!("识别失败：{e}")
                    } else {
                        format!("识别失败：{e}，已保留已识别的文字")
                    };
                    ui::hud_error(&self.app, &msg);
                    self.play_after_restore(SoundEvent::Error);
                } else if streamed {
                    ui::hud_hide(&self.app, 0);
                    // 流式定稿：有文字即完成；什么都没识别到按失败提示
                    if text.is_empty() {
                        self.play_after_restore(SoundEvent::Error);
                    }
                } else if text.is_empty() {
                    ui::hud(&self.app, "info", "没有识别到内容", ch);
                    ui::hud_hide(&self.app, 1000);
                    self.play_after_restore(SoundEvent::Error);
                } else {
                    ui::hud_hide(&self.app, 0);
                    self.insert(&text, ch);
                }
            }
            Mode::Pick | Mode::Compare => {
                let ms = self.released_at.map(|t| t.elapsed().as_millis() as u64);
                let Some(i) = self.rows.iter().position(|r| r.channel == ch) else { return };
                if self.mode == Mode::Pick && !matches!(self.rows[i].state, RowState::Listen | RowState::Wait) {
                    return;
                }
                let segs = &mut self.row_segs[i];
                segs.done(seg, res, false);
                let text = segs.text();
                let r = &mut self.rows[i];
                if !segs.finished() {
                    r.text = text;
                } else if !text.is_empty() {
                    r.text = text;
                    r.state = RowState::Final;
                    r.ms = Some(ms.unwrap_or(0));
                } else {
                    r.text = segs.error.clone().unwrap_or_else(|| "没有识别到内容".into());
                    r.state = RowState::Error;
                }
                let cur = self.rows[self.sel].state;
                let fallback = !self.user_picked || matches!(cur, RowState::Error | RowState::Skip);
                if self.rows[i].state == RowState::Final && fallback && cur != RowState::Final {
                    self.sel = i;
                }
                let finished = !self.rows.iter().any(|r| matches!(r.state, RowState::Listen | RowState::Wait));
                if self.choose_pending && matches!(self.rows[self.sel].state, RowState::Error | RowState::Skip) {
                    if let Some(j) = self.rows.iter().position(|r| r.state == RowState::Final) {
                        self.sel = j;
                    }
                }
                if self.mode == Mode::Pick && self.choose_pending && self.rows[self.sel].state == RowState::Final {
                    return self.choose(self.sel);
                }
                if finished {
                    self.choose_pending = false;
                    self.timeout_token += 1;
                }
                self.advance_pick();
                if self.mode == Mode::Idle {
                    return;
                }
                if finished {
                    if self.mode == Mode::Compare {
                        self.stop_recording();
                        self.mode = Mode::Idle;
                        self.tasks.clear();
                    }
                    // 全部行出结果：有可用结果时完成不另发声（完成信号由进入识别时的处理音承担）；
                    // 全部失败仍发失败音
                    if !self.rows.iter().any(|r| r.state == RowState::Final) {
                        self.play_after_restore(SoundEvent::Error);
                    }
                }
                self.emit_rows();
            }
            Mode::Idle => {}
        }
    }

    /// 说过话后静音超过设定时长即结束；一直没开口则 8 秒后放弃。设置里关闭后只能手动结束
    fn check_silence(&mut self, level: f32) {
        if !self.recording || !self.auto_stop || !self.settings.read().unwrap().silence_stop {
            return;
        }
        if level > 0.3 {
            self.speaking();
        } else {
            let limit = if self.heard_voice { self.settings().silence } else { 8.0 };
            if self.last_voice.elapsed().as_secs_f64() > limit {
                self.end();
            }
        }
    }

    /// 音量够大或识别文字仍在变化都算在说话：说话声小、离麦远时音量常低于阈值，单看音量会中途误判静音
    fn speaking(&mut self) {
        if self.recording {
            self.heard_voice = true;
            self.last_voice = Instant::now();
        }
    }

    fn end(&mut self) {
        if !self.recording {
            return;
        }
        self.stop_recording();
        // 进入识别处理时播「处理」音：等音量恢复窗口后再播，避免卡在还原淡入前半段听不清（Idle 无会话不发声）
        if !matches!(self.mode, Mode::Idle) {
            self.play_after_restore(SoundEvent::Processing);
        }
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
        self.advance_pick();
    }

    /// 打断：再按快捷键/Esc/超时；message 为 None 表示用户取消
    fn abort(&mut self, message: Option<String>) {
        if self.mode == Mode::Idle {
            return;
        }
        let mode = self.mode;
        let streamed = self.typer.is_some();
        let partial = match mode {
            Mode::Single(_) => self.segs.text(),
            Mode::Pick => self.rows.get(self.sel).map(|r| r.text.clone()).unwrap_or_default(),
            Mode::Compare | Mode::Idle => String::new(),
        };
        self.cancel();
        // 超时等异常打断发失败音；用户取消（message 为 None）保持安静
        if message.is_some() {
            self.play_after_restore(SoundEvent::Error);
        }
        if mode == Mode::Pick {
            if let Some(f) = self.front.take() {
                f.activate();
            }
        }
        if mode == Mode::Compare {
            for r in &mut self.rows {
                if matches!(r.state, RowState::Listen | RowState::Wait) {
                    r.state = RowState::Error;
                    if r.text.is_empty() {
                        r.text = message.clone().unwrap_or_else(|| "已取消".into());
                    }
                }
            }
            self.emit_rows();
            return;
        }
        // 超时打断时，非流式还没写进输入框的中间结果补上；用户主动取消不补写
        if message.is_some() && streamed {
            if let Mode::Single(ch) = mode {
                crate::history::record(&self.app, &self.output_text(partial.clone()), ch, true);
            }
        }
        if message.is_some() && !streamed && !partial.is_empty() {
            if mode == Mode::Pick {
                let text = partial.clone();
                let ch = self.rows.get(self.sel).map(|r| r.channel).unwrap_or(self.settings().channel);
                let app = self.app.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(80)).await;
                    deliver_text(&app, &text, ch);
                });
            } else if let Mode::Single(ch) = mode {
                self.insert(&partial, ch);
            }
        }
        match message {
            Some(m) if !partial.is_empty() => ui::hud_error(&self.app, &format!("{m}，已保留已识别的文字")),
            Some(m) => ui::hud_error(&self.app, &m),
            None => ui::hud_hide(&self.app, 0),
        }
    }

    fn cancel(&mut self) {
        self.gen += 1;
        self.timeout_token += 1;
        self.pick.reset();
        // 作废已排队/等待中的延迟提示音（处理音等）：松手后恢复窗口内取消（Esc/超时）不再出声（review #5）。
        // abort() 随后的 play_after_restore(Error) 在本次递增之后捕获代数，失败音不受影响。
        self.chime_gen.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        // 会话作废：本次未再压低音量，后续录音重新累计
        self.ducked = false;
        for t in self.tasks.drain(..) {
            t.abort();
        }
        // cancel 可能发生在预开麦阶段；丢弃 Primed 会经 Recorder::Drop 同步停麦。
        self.primed = None;
        self.llm.stop();
        self.sel_final = false;
        self.finalized = None;
        self.stop_recording();
        if let Some(mut t) = self.typer.take() {
            t.finish();
        }
        if self.mode == Mode::Pick {
            self.hk.picking.store(false, Ordering::Relaxed);
            ui::pick_hide(&self.app);
        }
        self.history = None;
        self.mode = Mode::Idle;
    }

    fn final_selectable(&self) -> bool {
        self.finalized
            .as_ref()
            .is_some_and(|f| matches!(f.state, LlmState::Ready | LlmState::Skipped) && !f.text.is_empty())
    }

    fn pick_key(&mut self, k: Special) {
        let enabled = self.settings().history_enabled;
        let k = match route_pick_key(&mut self.history, k, || HistoryView { items: crate::history::list(), sel: 0, enabled }) {
            PickKey::Rows(k) => k,
            PickKey::Opened => {
                // 看历史即用户接管：不再自动评选或代为上屏，免得在看历史时被插入候选
                self.take_manual();
                self.choose_pending = false;
                return self.emit_rows();
            }
            PickKey::Stay | PickKey::Closed => return self.emit_rows(),
            PickKey::Choose(i) => return self.choose_history(i),
        };
        let n = self.rows.len();
        if n == 0 {
            return;
        }
        let has_final_row = self.final_selectable();
        if matches!(k, Special::Up | Special::Down | Special::Digit(_))
            || (k == Special::Enter && !(self.sel_final && has_final_row))
        {
            self.take_manual();
        }
        match k {
            Special::Up | Special::Down => {
                if has_final_row {
                    if self.sel_final {
                        self.sel_final = false;
                        self.sel = if k == Special::Down { 0 } else { n - 1 };
                    } else if k == Special::Down && self.sel + 1 == n {
                        self.sel_final = true;
                    } else if k == Special::Up && self.sel == 0 {
                        self.sel_final = true;
                    } else {
                        self.sel = if k == Special::Down { self.sel + 1 } else { self.sel - 1 };
                    }
                } else {
                    self.sel_final = false;
                    self.sel = if k == Special::Down { (self.sel + 1) % n } else { (self.sel + n - 1) % n };
                }
                self.user_picked = true;
                self.emit_rows();
            }
            Special::Digit(d) => {
                let i = d as usize - 1;
                if i >= n {
                    return;
                }
                if !self.sel_final && self.sel == i {
                    self.choose(i);
                } else {
                    self.sel_final = false;
                    self.sel = i;
                    self.user_picked = true;
                    self.emit_rows();
                }
            }
            Special::Enter => {
                if self.sel_final && has_final_row {
                    self.choose_final();
                } else {
                    self.choose(self.sel);
                }
            }
            Special::Escape => self.abort(None),
            Special::Tab => {}
        }
    }

    /// 选中顶部的「最终定稿」行上屏
    fn choose_final(&mut self) {
        let Some(f) = self.finalized.clone() else { return };
        if !matches!(f.state, LlmState::Ready | LlmState::Skipped) || f.text.is_empty() {
            return;
        }
        let ch = f.source_channel.unwrap_or(Channel::All);
        let front = self.front.take();
        let app = self.app.clone();
        let text = f.text;
        self.cancel();
        tauri::async_runtime::spawn(async move {
            if let Some(f) = front {
                f.activate();
            }
            tokio::time::sleep(Duration::from_millis(80)).await;
            deliver_text(&app, &text, ch);
        });
    }

    /// 历史条目上屏：结束本轮并关面板，原文直接粘贴，不再记入历史
    fn choose_history(&mut self, i: usize) {
        let Some(entry) = self.history.as_ref().and_then(|h| h.items.get(i)).cloned() else { return };
        let front = self.front.take();
        let app = self.app.clone();
        self.cancel();
        tauri::async_runtime::spawn(async move {
            if let Some(f) = front {
                f.activate();
            }
            tokio::time::sleep(Duration::from_millis(80)).await;
            paste_or_copy(&app, &entry.text, entry.channel);
        });
    }

    /// 选中一行上屏；聆听/识别中的行先结束录音，定稿后自动上屏；失败的行抖动提示
    fn choose(&mut self, i: usize) {
        let Some(r) = self.rows.get(i) else { return };
        if matches!(r.state, RowState::Listen | RowState::Wait) {
            self.sel = i;
            self.user_picked = true;
            self.choose_pending = true;
            self.end();
            self.emit_rows();
            return;
        }
        if r.state != RowState::Final {
            self.sel = i;
            self.user_picked = true;
            self.emit_rows();
            let _ = self.app.emit_to("pick", "pick-shake", i);
            return;
        }
        let text = r.text.clone();
        let ch = r.channel;
        crate::update_settings(&self.app, |s| {
            s.last_pick = Some(ch);
            *s.pick_counts.entry(ch).or_default() += 1;
        });
        let front = self.front.take();
        let app = self.app.clone();
        self.cancel();
        tauri::async_runtime::spawn(async move {
            if let Some(f) = front {
                f.activate();
            }
            tokio::time::sleep(Duration::from_millis(80)).await;
            deliver_text(&app, &text, ch);
        });
    }

    /// 用户做了选择类操作：从此不再自动评选，进行中的 Jev / LLM 结果作废
    fn take_manual(&mut self) {
        self.manual = true;
        if self.jev == JevState::Busy {
            self.jev_token += 1;
            self.jev = JevState::Idle;
        }
        // 还没出结果的定稿行随手选作废：中止在途请求（不再计费），行也收起，免得一直显示「等待中」
        if self.finalized.as_ref().is_some_and(|f| matches!(f.state, LlmState::Idle | LlmState::Busy)) {
            self.llm.stop();
            self.finalized = None;
            self.sel_final = false;
        }
    }

    fn llm_active(&self) -> bool {
        self.settings().llm.is_ready()
    }

    /// 仅为有效 Jev 提前评选；停录后达到本次录音快照的门槛立即推进，否则从首条可用定稿起等待快照时长。
    /// Jev 关闭或配置不可用时保留候选供手选，不提前封存慢渠道。
    /// 人工等待中的渠道不被比例阈值抢占；宽限到期仍可回退到已有定稿。
    ///
    /// Advance early only for valid Jev. After recording stops, use the snapshotted threshold or wait duration from the first available final.
    /// Disabled or invalid Jev leaves candidates for manual selection without sealing slow channels early.
    /// The threshold cannot preempt a pending manual choice, which may still fall back to a final when grace expires.
    fn advance_pick(&mut self) {
        if self.mode != Mode::Pick || self.recording {
            return;
        }
        let has_final = self.rows.iter().any(|r| r.state == RowState::Final);
        if has_final {
            self.timeout_token += 1;
        }
        let auto = self.llm_active() || self.settings().jev.targets().is_ok();
        let mut waiting = self.rows.iter().any(|r| matches!(r.state, RowState::Listen | RowState::Wait));
        if waiting && auto && !self.manual && !self.choose_pending && jev_ready(&self.rows, self.pick.threshold) {
            self.finish_slow_rows();
            waiting = false;
        }
        if waiting && has_final && ((auto && !self.manual) || self.choose_pending) {
            if let Some(token) = self.pick.arm(Instant::now()) {
                let (gen, tx) = (self.gen, self.tx.clone());
                let wait = self.pick.wait;
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(wait).await;
                    let _ = tx.send(Msg::PickGrace { gen, token });
                });
            }
        } else {
            self.pick.cancel_grace();
        }
        if self.choose_pending && matches!(self.rows[self.sel].state, RowState::Error | RowState::Skip) {
            if let Some(i) = self.rows.iter().position(|r| r.state == RowState::Final) {
                self.sel = i;
            }
        }
        if self.choose_pending && self.rows[self.sel].state == RowState::Final {
            return self.choose(self.sel);
        }
        if !waiting {
            self.choose_pending = false;
            if self.llm_active() {
                self.maybe_llm();
            } else {
                self.maybe_jev();
            }
        }
    }

    /// 封存未完成行而不覆盖文字；分段也标记完成，续录后旧回调不能重新打开这些片段。
    ///
    /// Seal unfinished rows without overwriting text, and finish their segments so stale callbacks cannot reopen them after resuming.
    fn finish_slow_rows(&mut self) {
        seal_slow_rows(&mut self.rows, &mut self.row_segs);
    }

    /// 有效 Jev 配置评选多条定稿，只有一条时直接上屏；Jev 关闭、配置不可用或评选失败时保留手选。
    ///
    /// Use configured Jev for multiple finals and paste a sole result. Disabled, invalid, or failed Jev leaves selection to the user.
    fn maybe_jev(&mut self) {
        if self.mode != Mode::Pick || self.recording || self.choose_pending || self.manual || self.jev != JevState::Idle {
            return;
        }
        let cfg = self.settings().jev;
        if cfg.targets().is_err() {
            return;
        }
        let finals = jev_finals(&self.rows);
        match finals.as_slice() {
            [] => {}
            [(i, _)] => self.choose(*i),
            _ => {
                // 评选已接管后续流程，使识别超时失效；慢渠道不得打断 Jev 或关闭评选失败后的手选面板。
                //
                // Invalidate the recognition timeout once selection takes over, so slow channels cannot interrupt Jev or close the manual picker after failure.
                self.timeout_token += 1;
                self.jev = JevState::Busy;
                self.jev_token += 1;
                let (gen, token, tx) = (self.gen, self.jev_token, self.tx.clone());
                let (idxs, texts): (Vec<usize>, Vec<String>) = finals.into_iter().unzip();
                tauri::async_runtime::spawn(async move {
                    let res = voicekey_core::jev::pick(&cfg, &texts)
                        .await
                        .map_err(|e| e.to_string())
                        .and_then(|p| idxs.get(p.index).copied().ok_or_else(|| format!("Jev 返回了无效序号 {}", p.index)));
                    let _ = tx.send(Msg::JevDone { gen, token, res });
                });
                self.emit_rows();
            }
        }
    }

    fn jev_done(&mut self, gen: u64, token: u64, res: Result<usize, String>) {
        if gen != self.gen || token != self.jev_token || self.mode != Mode::Pick {
            return;
        }
        match res {
            Ok(i) if self.rows.get(i).is_some_and(|r| r.state == RowState::Final) => {
                self.jev = JevState::Idle;
                self.choose(i);
            }
            _ => {
                self.jev = JevState::Failed;
                self.emit_rows();
            }
        }
    }

    /// 启用 LLM 融合定稿时：单条定稿直接采纳；多条定稿先尝试本地高相似度跳过（省 Token），未命中再调 OpenAI 兼容 API
    fn maybe_llm(&mut self) {
        if self.mode != Mode::Pick || self.recording || self.choose_pending || self.manual {
            return;
        }
        if self.finalized.as_ref().is_some_and(|f| f.state != LlmState::Idle) {
            return;
        }
        let cfg = self.settings().llm;
        if !cfg.is_ready() {
            return;
        }
        let finals: Vec<(usize, Channel, String, Option<u64>)> = self
            .rows
            .iter()
            .enumerate()
            .filter(|(_, r)| r.state == RowState::Final && !r.text.is_empty())
            .map(|(i, r)| (i, r.channel, r.text.clone(), r.ms))
            .collect();
        if finals.is_empty() {
            return;
        }
        if finals.len() == 1 {
            let (_, ch, text, _) = finals.into_iter().next().unwrap();
            self.timeout_token += 1;
            self.finalized = Some(FinalizedRow {
                state: LlmState::Skipped,
                text,
                ms: Some(0),
                note: Some("仅 1 路有效定稿 · 已省去 LLM".into()),
                source_channel: Some(ch),
            });
            if cfg.auto_insert {
                self.choose_final();
            } else {
                self.sel_final = true;
                self.emit_rows();
            }
            return;
        }

        let candidates: Vec<voicekey_core::llm::CandidateInput> = finals
            .iter()
            .map(|(_, ch, text, ms)| voicekey_core::llm::CandidateInput {
                channel: ch.id().to_string(),
                text: text.clone(),
                elapsed_ms: *ms,
                hints: Vec::new(),
            })
            .collect();
        let pref: Vec<usize> = (0..finals.len()).collect();

        // 本地高相似度跳过（省 Token）
        if let Some(skip) = voicekey_core::llm::try_skip_similar(&cfg, &candidates, &pref) {
            let (_, ch, text, _) = &finals[skip.picked_index];
            self.timeout_token += 1;
            self.finalized = Some(FinalizedRow {
                state: LlmState::Skipped,
                text: text.clone(),
                ms: Some(0),
                note: Some(format!(
                    "{} 路一致 · 相似度 {:.0}% · 已省去 LLM",
                    skip.agree_count,
                    skip.avg_similarity * 100.0
                )),
                source_channel: Some(*ch),
            });
            if cfg.auto_insert {
                self.choose_final();
            } else {
                self.sel_final = true;
                self.emit_rows();
            }
            return;
        }

        // 调用 OpenAI 兼容 LLM 接口融合定稿
        self.timeout_token += 1;
        self.finalized = Some(FinalizedRow {
            state: LlmState::Busy,
            text: String::new(),
            ms: None,
            note: Some(cfg.model.clone()),
            source_channel: None,
        });
        let (gen, tx) = (self.gen, self.tx.clone());
        self.llm.start(move |token| {
            let dtx = tx.clone();
            let on_delta: Option<voicekey_core::llm::OnDelta> = cfg.stream.then(|| {
                Box::new(move |text: &str| {
                    let _ = dtx.send(Msg::LlmDelta { gen, token, text: text.to_string() });
                }) as voicekey_core::llm::OnDelta
            });
            tauri::async_runtime::spawn(async move {
                let res = voicekey_core::llm::fuse(&cfg, &candidates, on_delta)
                    .await
                    .map_err(|e| format!("{e:#}"));
                let _ = tx.send(Msg::LlmDone { gen, token, res });
            })
        });
        self.emit_rows();
    }

    fn llm_delta(&mut self, gen: u64, token: u64, text: String) {
        if gen != self.gen || !self.llm.is_current(token) || self.mode != Mode::Pick {
            return;
        }
        if let Some(f) = self.finalized.as_mut() {
            if f.state == LlmState::Busy {
                f.text = text;
                self.emit_rows();
            }
        }
    }

    fn llm_done(&mut self, gen: u64, token: u64, res: Result<voicekey_core::llm::FuseResult, String>) {
        if gen != self.gen || !self.llm.is_current(token) || self.mode != Mode::Pick {
            return;
        }
        self.llm.task = None;
        let cfg = self.settings().llm;
        let (row, next) = llm_finish(res, &self.rows, self.sel, cfg.auto_insert && !self.manual);
        self.finalized = Some(row);
        match next {
            LlmNext::InsertFinal => self.choose_final(),
            LlmNext::InsertRow(i) => self.choose(i),
            LlmNext::FocusFinal => {
                self.sel_final = true;
                self.emit_rows();
            }
            LlmNext::FocusRow(i) => {
                self.sel_final = false;
                self.sel = i;
                self.emit_rows();
            }
            LlmNext::Nothing => {
                self.sel_final = false;
                self.emit_rows();
            }
        }
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
        let model = Model {
            recording: self.recording,
            rows: &self.rows,
            sel: self.sel,
            jev: self.jev,
            finalized: self.finalized.as_ref(),
            sel_final: self.sel_final,
            history: self.history.as_ref(),
        };
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

/// 跳过的渠道不计入参与数，错误仍计入参与数但不算成功；所有参与渠道终结后允许使用不足阈值的定稿回退。
/// 按所选比例向上取整，例如默认八个参与渠道需要六条 Final，任何中间文本都不计数。
///
/// Skipped channels do not participate; errors participate but do not count as successes. Once all channels end, allow fallback below the threshold.
/// Round the selected ratio up: by default eight participants require six Final rows; partial text never counts.
fn jev_ready(rows: &[Row], threshold: SelectionThreshold) -> bool {
    let participating = rows.iter().filter(|r| r.state != RowState::Skip).count();
    let finals = rows.iter().filter(|r| r.state == RowState::Final).count();
    participating > 0 && (threshold.reached(finals, participating) || !rows.iter().any(|r| matches!(r.state, RowState::Listen | RowState::Wait)))
}

/// 取出已定稿的行（rows 下标, 文字），按 rows 顺序；Error/Skip/聆听中的行不参与评选
fn jev_finals(rows: &[Row]) -> Vec<(usize, String)> {
    rows.iter().enumerate().filter(|(_, r)| r.state == RowState::Final).map(|(i, r)| (i, r.text.clone())).collect()
}

fn seal_slow_rows(rows: &mut [Row], segments: &mut [Segments]) {
    for (row, segs) in rows.iter_mut().zip(segments) {
        if matches!(row.state, RowState::Listen | RowState::Wait) {
            row.state = RowState::Error;
            for (_, done) in &mut segs.parts {
                *done = true;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{jev_finals, seal_slow_rows, JevConfig, PickProgress, Row, RowState, Segments, SelectionThreshold};
    use std::time::{Duration, Instant};
    use crate::settings::Channel;

    fn row(channel: Channel, state: RowState, text: &str) -> Row {
        Row { channel, text: text.into(), state, ms: None }
    }

    fn jev_ready(rows: &[Row]) -> bool {
        super::jev_ready(rows, SelectionThreshold::default())
    }

    #[test]
    fn selection_settings_are_snapshotted_until_next_recording_or_resume() {
        let now = Instant::now();
        let mut config = JevConfig { selection_threshold: SelectionThreshold::All, selection_wait_ms: 5000, ..JevConfig::default() };
        let mut pick = PickProgress::default();
        pick.begin(config.clone());
        config.selection_threshold = SelectionThreshold::Half;
        config.selection_wait_ms = 500;
        let old = pick.arm(now).unwrap();
        assert_eq!(pick.threshold, SelectionThreshold::All);
        assert!(!pick.expired(old, now + Duration::from_millis(4999)));
        assert!(pick.expired(old, now + Duration::from_millis(5000)));
        pick.begin(config);
        assert_eq!(pick.threshold, SelectionThreshold::Half);
        assert!(!pick.expired(old, now + Duration::from_secs(9)));
        let next = pick.arm(now).unwrap();
        assert!(!pick.expired(next, now + Duration::from_millis(499)));
        assert!(pick.expired(next, now + Duration::from_millis(500)));
    }

    #[test]
    fn each_threshold_excludes_skips_but_keeps_errors_in_participants() {
        let mut rows = vec![row(Channel::Doubao, RowState::Final, "定稿"); 2];
        rows.push(row(Channel::Qwen, RowState::Wait, "中间结果"));
        rows.push(row(Channel::Baidu, RowState::Error, "失败"));
        rows.push(row(Channel::Offline, RowState::Skip, "跳过"));
        assert!(super::jev_ready(&rows, SelectionThreshold::Half));
        assert!(!super::jev_ready(&rows, SelectionThreshold::TwoThirds));
        assert!(!super::jev_ready(&rows, SelectionThreshold::All));
        rows[3].state = RowState::Skip;
        assert!(super::jev_ready(&rows, SelectionThreshold::TwoThirds));
        assert!(!super::jev_ready(&rows, SelectionThreshold::All));
        rows[2].state = RowState::Error;
        assert!(super::jev_ready(&rows, SelectionThreshold::All));
    }

    #[test]
    fn grace_is_armed_once_and_keeps_full_duration_after_a_late_first_final() {
        let stopped = Instant::now();
        let first = stopped + Duration::from_millis(14900);
        let mut pick = PickProgress::default();
        let token = pick.arm(first).unwrap();
        assert!(pick.arm(first + Duration::from_secs(1)).is_none());
        assert!(!pick.expired(token, stopped + Duration::from_secs(15)));
        assert!(!pick.expired(token, first + Duration::from_millis(2499)));
        assert!(pick.expired(token, first + Duration::from_millis(2500)));
    }

    #[test]
    fn threshold_completion_and_resume_invalidate_old_grace_tokens() {
        let now = Instant::now();
        let mut pick = PickProgress::default();
        let token = pick.arm(now).unwrap();
        pick.cancel_grace();
        assert!(!pick.expired(token, now + Duration::from_secs(3)));
        let resumed = pick.arm(now).unwrap();
        pick.reset();
        assert!(!pick.expired(resumed, now + Duration::from_secs(3)));
        assert!(pick.arm(now).is_some());
    }

    #[test]
    fn sealing_slow_rows_keeps_partial_text_and_rejects_old_segments_after_resume() {
        let mut rows = vec![row(Channel::Doubao, RowState::Final, "定稿"), row(Channel::Qwen, RowState::Wait, "中间文字")];
        let mut segments = vec![Segments::default(), Segments::default()];
        let old = segments[1].start();
        segments[1].partial(old, "中间文字".into());
        seal_slow_rows(&mut rows, &mut segments);
        assert_eq!(rows[0].state, RowState::Final);
        assert_eq!(rows[1].state, RowState::Error);
        assert_eq!(rows[1].text, "中间文字");
        assert!(segments[1].finished());
        let new = segments[1].start();
        assert_eq!(segments[1].partial(old, "迟到中间结果".into()), None);
        segments[1].done(old, Ok("迟到定稿".into()), false);
        assert!(!segments[1].finished());
        assert_eq!(segments[1].text(), "中间文字");
        segments[1].done(new, Ok("续录".into()), false);
        assert_eq!(segments[1].text(), "中间文字续录");
    }

    #[test]
    fn jev_threshold_rounds_up_for_each_participating_channel_count() {
        for (participating, required) in [(1, 1), (2, 2), (3, 2), (4, 3), (5, 4), (6, 4), (7, 5), (8, 6), (9, 6)] {
            let mut rows = vec![row(Channel::Doubao, RowState::Wait, "尚未定稿"); participating];
            for r in rows.iter_mut().take(required - 1) {
                r.state = RowState::Final;
            }
            assert!(!jev_ready(&rows), "{participating} channels must wait below {required} finals");
            rows[required - 1].state = RowState::Final;
            assert!(jev_ready(&rows), "{participating} channels are ready at {required} finals");
        }
    }

    #[test]
    fn jev_skip_is_excluded_but_error_is_not_a_success() {
        let mut rows = vec![row(Channel::Doubao, RowState::Final, "最终结果"); 5];
        rows.push(row(Channel::Qwen, RowState::Wait, "中间结果"));
        rows.push(row(Channel::Baidu, RowState::Listen, "仍在识别"));
        rows.push(row(Channel::Offline, RowState::Error, "失败"));
        assert!(!jev_ready(&rows));

        rows[7].state = RowState::Skip;
        assert!(jev_ready(&rows));
        assert_eq!(jev_finals(&rows).len(), 5);

        rows[7].state = RowState::Error;
        rows[5].state = RowState::Final;
        assert!(jev_ready(&rows));
        assert_eq!(jev_finals(&rows).len(), 6);
    }

    #[test]
    fn jev_all_channels_ended_allows_zero_one_or_multiple_finals_below_threshold() {
        for final_count in 0..=2 {
            let mut rows = vec![row(Channel::Doubao, RowState::Error, "识别失败"); 8];
            for r in rows.iter_mut().take(final_count) {
                r.state = RowState::Final;
                r.text = "最终结果".into();
            }
            rows[7].state = RowState::Wait;
            assert!(!jev_ready(&rows));
            rows[7].state = RowState::Error;
            assert!(jev_ready(&rows));
            assert_eq!(jev_finals(&rows).len(), final_count);
        }

        assert!(!jev_ready(&[]));
        assert!(!jev_ready(&[row(Channel::Offline, RowState::Skip, "跳过")]));
    }

    #[test]
    fn jev_resumed_rows_wait_for_new_finals_and_candidates_are_a_snapshot() {
        let mut rows = vec![row(Channel::Doubao, RowState::Final, "上一段"); 3];
        let candidates = jev_finals(&rows);
        for r in &mut rows {
            r.state = RowState::Listen;
            r.text = "上一段和续录中间结果".into();
        }
        assert!(!jev_ready(&rows));
        assert!(jev_finals(&rows).is_empty());

        rows[0].state = RowState::Final;
        rows[1].state = RowState::Final;
        assert!(jev_ready(&rows));
        assert_eq!(jev_finals(&rows).len(), 2);
        assert_eq!(candidates, vec![(0, "上一段".into()), (1, "上一段".into()), (2, "上一段".into())]);
    }

    #[test]
    fn jev_finals_keeps_only_final_rows_with_their_row_index() {
        assert!(jev_finals(&[]).is_empty());
        assert!(jev_finals(&[row(Channel::Doubao, RowState::Error, "超时"), row(Channel::Qwen, RowState::Skip, "跳过")]).is_empty());

        let one = [row(Channel::Doubao, RowState::Error, "超时"), row(Channel::Qwen, RowState::Final, "你好")];
        assert_eq!(jev_finals(&one), vec![(1, "你好".to_string())]);

        let many = [
            row(Channel::Doubao, RowState::Final, "今天开会"),
            row(Channel::Wetype, RowState::Error, "失败"),
            row(Channel::Qwen, RowState::Skip, "离线模型未下载，已跳过"),
            row(Channel::Baidu, RowState::Final, "今天开灰"),
            row(Channel::Sogou, RowState::Wait, ""),
            row(Channel::Iflytek, RowState::Final, "今天开会。"),
        ];
        assert_eq!(jev_finals(&many), vec![(0, "今天开会".to_string()), (3, "今天开灰".to_string()), (5, "今天开会。".to_string())]);
    }

    #[test]
    fn resumed_segments_join_in_order_and_wait_for_all() {
        let mut s = Segments::default();
        let a = s.start();
        assert_eq!(s.partial(a, "今天".into()), Some(true));
        let b = s.start();
        assert_eq!(s.partial(b, "天气".into()), Some(true));
        assert_eq!(s.partial(b, "天气".into()), Some(false));
        s.done(b, Ok("天气不错。".into()), false);
        assert!(!s.finished());
        s.done(a, Ok("今天，".into()), false);
        assert!(s.finished());
        assert_eq!(s.text(), "今天，天气不错。");
        assert_eq!(s.partial(a, "迟到".into()), None);
    }

    #[test]
    fn failed_segment_keeps_partial_text_and_reports_error() {
        let mut s = Segments::default();
        let a = s.start();
        let b = s.start();
        s.partial(b, "半句".into());
        s.done(a, Ok("第一句".into()), false);
        s.done(b, Err("网络".into()), false);
        assert_eq!(s.text(), "第一句半句");
        assert_eq!(s.error.as_deref(), Some("网络"));

        let mut timed_out = Segments::default();
        let d = timed_out.start();
        timed_out.partial(d, "已经打出来的字".into());
        timed_out.done(d, Err("识别超时".into()), false);
        assert_eq!(timed_out.text(), "已经打出来的字");

        let mut streamed = Segments::default();
        let c = streamed.start();
        streamed.partial(c, "已上屏".into());
        streamed.done(c, Ok(String::new()), true);
        assert_eq!(streamed.text(), "已上屏");
    }

    #[test]
    fn secure_input_blocks_streaming_and_paste() {
        assert!(super::allow_text_input(true, false));
        assert!(!super::allow_text_input(true, true));
        assert!(!super::allow_text_input(false, false));
        assert!(!super::allow_text_input(false, true));
        assert_eq!(super::CLIPBOARD_HINT, "没有可输入的位置，文字已复制到剪贴板");
    }

    #[test]
    fn force_paste_overrides_missing_target() {
        assert!(super::should_paste(true, false));
        assert!(!super::should_paste(false, false));
        assert!(super::should_paste(false, true));
        assert!(super::should_paste(true, true));
        assert!(super::should_paste(super::allow_text_input(false, false), true));
        assert!(!super::should_paste(super::allow_text_input(false, false), false));
    }

    fn view(n: usize, enabled: bool) -> super::HistoryView {
        let items = (0..n)
            .map(|i| crate::history::HistoryEntry { text: format!("h{i}"), ts: 0, channel: Channel::Doubao, delivered: true })
            .collect();
        super::HistoryView { items, sel: 0, enabled }
    }

    #[test]
    fn tab_opens_history_and_tab_or_escape_returns_to_rows() {
        use super::{route_pick_key, PickKey};
        use voicekey_platform::Special;
        let mut h = None;
        assert_eq!(route_pick_key(&mut h, Special::Digit(2), || view(3, true)), PickKey::Rows(Special::Digit(2)));
        assert!(h.is_none());
        for back in [Special::Tab, Special::Escape] {
            assert_eq!(route_pick_key(&mut h, Special::Tab, || view(3, true)), PickKey::Opened);
            assert_eq!(h.as_ref().unwrap().items.len(), 3);
            // 打开期间候选键全归历史
            assert_eq!(route_pick_key(&mut h, Special::Enter, || unreachable!()), PickKey::Choose(0));
            assert_eq!(route_pick_key(&mut h, back, || unreachable!()), PickKey::Closed);
            assert!(h.is_none());
        }
        assert_eq!(route_pick_key(&mut h, Special::Escape, || view(3, true)), PickKey::Rows(Special::Escape));
    }

    #[test]
    fn history_keys_move_select_and_choose() {
        use super::PickKey;
        use voicekey_platform::Special;
        let mut h = view(3, true);
        assert_eq!(h.key(Special::Up), PickKey::Stay);
        assert_eq!(h.sel, 2);
        assert_eq!(h.key(Special::Down), PickKey::Stay);
        assert_eq!(h.sel, 0);
        assert_eq!(h.key(Special::Digit(2)), PickKey::Stay);
        assert_eq!(h.sel, 1);
        assert_eq!(h.key(Special::Digit(2)), PickKey::Choose(1));
        assert_eq!(h.key(Special::Digit(9)), PickKey::Stay);
        assert_eq!(h.sel, 1);
        assert_eq!(h.key(Special::Enter), PickKey::Choose(1));
    }

    #[test]
    fn disabled_or_empty_history_only_shows_hint_and_returns() {
        use super::{route_pick_key, PickKey};
        use voicekey_platform::Special;
        let mut h = None;
        assert_eq!(route_pick_key(&mut h, Special::Tab, || view(0, false)), PickKey::Opened);
        assert!(!h.as_ref().unwrap().enabled);
        for k in [Special::Enter, Special::Digit(1), Special::Up, Special::Down] {
            assert_eq!(route_pick_key(&mut h, k, || unreachable!()), PickKey::Stay);
        }
        assert_eq!(route_pick_key(&mut h, Special::Tab, || unreachable!()), PickKey::Closed);
        assert!(h.is_none());
    }

    fn fused(text: &str) -> voicekey_core::llm::FuseResult {
        voicekey_core::llm::FuseResult { text: text.into(), ms: 5, model: "m".into(), usage: None, system_prompt: String::new(), user_prompt: String::new() }
    }

    #[test]
    fn llm_success_offers_or_inserts_the_fused_text() {
        use super::{llm_finish, LlmNext, LlmState};
        let rows = [row(Channel::Doubao, RowState::Final, "a"), row(Channel::Qwen, RowState::Final, "b")];
        let (f, next) = llm_finish(Ok(fused("合并")), &rows, 0, false);
        assert_eq!((f.state, f.text.as_str(), next), (LlmState::Ready, "合并", LlmNext::FocusFinal));
        assert_eq!(llm_finish(Ok(fused("合并")), &rows, 0, true).1, LlmNext::InsertFinal);
    }

    #[test]
    fn llm_failure_falls_back_to_an_original_final() {
        use super::{llm_finish, LlmNext, LlmState};
        let rows = [row(Channel::Doubao, RowState::Error, ""), row(Channel::Qwen, RowState::Final, "b"), row(Channel::Baidu, RowState::Final, "c")];
        // 选中行是定稿就用它，否则取第一条定稿
        assert_eq!(llm_finish(Err("超时".into()), &rows, 2, false).1, LlmNext::FocusRow(2));
        let (f, next) = llm_finish(Err("超时".into()), &rows, 0, true);
        assert_eq!((f.state, next), (LlmState::Failed, LlmNext::InsertRow(1)));
        assert!(f.note.unwrap().contains(Channel::Qwen.title()));
        let none = [row(Channel::Doubao, RowState::Error, "")];
        assert_eq!(llm_finish(Err("x".into()), &none, 0, true).1, LlmNext::Nothing);
    }

    #[test]
    fn llm_job_stop_aborts_the_request_and_rejects_stale_results() {
        use std::sync::mpsc::{channel, RecvTimeoutError};
        let mut job = super::LlmJob::default();
        let (tx, rx) = channel::<()>();
        job.start(|_| tauri::async_runtime::spawn(async move {
            let _alive = tx;
            std::future::pending::<()>().await
        }));
        let token = job.token;
        assert!(job.is_current(token));
        job.stop();
        assert!(!job.is_current(token));
        // 任务被中止、持有的发送端随之释放，说明请求 future 已被丢弃（连接随之关闭）
        assert_eq!(rx.recv_timeout(Duration::from_secs(2)), Err(RecvTimeoutError::Disconnected));
    }
}
