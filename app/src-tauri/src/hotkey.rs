//! 长按键：按住超过阈值开始、松开结束。点按快捷键：单个修饰键在阈值内松开，或 组合键按下（吞掉不传给前台 App）
use crate::settings::Shortcut;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::mpsc::UnboundedSender;
use voicekey_platform::{self as pf, KeyEvent, KeyKind, Special};

const THRESHOLD: Duration = Duration::from_millis(300);
const MOD_MASK: u8 = pf::CTRL | pf::ALT | pf::SHIFT | pf::META;

#[derive(Debug, Clone)]
pub enum HotEvent {
    Press,
    LongPress,
    Release,
    Tap,
    Escape,
    Pick(Special),
    Recorded(Option<Shortcut>),
}

#[derive(Default)]
pub struct Config {
    pub hold: u32,
    pub tap: Option<Shortcut>,
}

#[derive(Default)]
pub struct Shared {
    pub config: RwLock<Config>,
    /// 候选面板打开时吞掉方向键/数字/回车/Esc
    pub picking: AtomicBool,
    /// 设置里录制快捷键
    pub recording: AtomicBool,
    /// 托盘「暂停监听」
    pub paused: AtomicBool,
}

#[derive(Default)]
struct State {
    down_code: Option<u32>,
    swallowed_code: Option<u32>,
    pressed_at: Option<Instant>,
    cancelled: bool,
    active: bool,
    gen: u64,
    /// Windows：被吞掉、尚未重放的修饰键按下
    held_swallowed: bool,
    tapped: bool,
    /// 录制：单独按下的修饰键（多个修饰键同时按下时为 None 且 multi=true）
    rec_pending: Option<u32>,
    rec_multi: bool,
}

pub fn start(shared: Arc<Shared>, tx: UnboundedSender<HotEvent>) {
    let state = Arc::new(Mutex::new(State::default()));
    pf::start_hook(Box::new(move |e| handle(&shared, &state, &tx, e)));
}

fn handle(sh: &Shared, st: &Arc<Mutex<State>>, tx: &UnboundedSender<HotEvent>, e: &KeyEvent) -> bool {
    if sh.recording.load(Ordering::Relaxed) {
        return record(sh, &mut st.lock().unwrap(), tx, e);
    }
    if e.kind == KeyKind::Down && sh.picking.load(Ordering::Relaxed) {
        if let Some(k) = pf::special(e.code) {
            let _ = tx.send(HotEvent::Pick(k));
            return true;
        }
    }
    if sh.paused.load(Ordering::Relaxed) {
        return false;
    }
    let cfg = sh.config.read().unwrap();
    let mut s = st.lock().unwrap();
    match e.kind {
        KeyKind::Down => {
            if pf::special(e.code) == Some(Special::Escape) && !e.repeat {
                let _ = tx.send(HotEvent::Escape);
            }
            if let Some(t) = cfg.tap.as_ref().filter(|t| !t.is_modifier()) {
                if e.code == t.code && e.mods & MOD_MASK == t.mods {
                    s.swallowed_code = Some(e.code);
                    if !e.repeat {
                        let _ = tx.send(HotEvent::Tap);
                    }
                    return true;
                }
            }
            if s.down_code.is_some() && !s.active {
                cancel_pending(&mut s);
            }
            false
        }
        KeyKind::Up => {
            if s.swallowed_code == Some(e.code) {
                s.swallowed_code = None;
                return true;
            }
            false
        }
        KeyKind::Modifier(pressed) => {
            let tap_code = cfg.tap.as_ref().filter(|t| t.is_modifier()).map(|t| t.code);
            let ours = e.code == s.down_code.unwrap_or(e.code) && (e.code == cfg.hold || Some(e.code) == tap_code);
            if !ours {
                if s.down_code.is_some() && !s.active {
                    cancel_pending(&mut s);
                }
                return false;
            }
            if pressed && s.down_code.is_none() {
                s.down_code = Some(e.code);
                s.pressed_at = Some(Instant::now());
                s.cancelled = false;
                s.tapped = false;
                s.gen += 1;
                let _ = tx.send(HotEvent::Press);
                if e.code == cfg.hold {
                    let (gen, st, tx) = (s.gen, st.clone(), tx.clone());
                    std::thread::spawn(move || {
                        std::thread::sleep(THRESHOLD);
                        let mut s = st.lock().unwrap();
                        if s.gen == gen && s.down_code.is_some() && !s.cancelled {
                            s.active = true;
                            let _ = tx.send(HotEvent::LongPress);
                        }
                    });
                }
                s.held_swallowed = cfg!(windows);
                return s.held_swallowed;
            }
            if pressed {
                return s.held_swallowed;
            }
            if s.down_code.is_none() {
                return false;
            }
            s.down_code = None;
            s.gen += 1;
            let swallowed = std::mem::take(&mut s.held_swallowed);
            if s.active {
                s.active = false;
                let _ = tx.send(HotEvent::Release);
            } else if Some(e.code) == tap_code
                && !s.cancelled
                && s.pressed_at.is_some_and(|t| t.elapsed() < THRESHOLD)
            {
                s.tapped = true;
                let _ = tx.send(HotEvent::Tap);
            } else if swallowed {
                // 普通短按：原样重放
                pf::inject_key(e.code, true);
                pf::inject_key(e.code, false);
            }
            swallowed
        }
    }
}

/// 按住期间按了别的键：放弃本次长按/点按，并把吞掉的修饰键补发给系统以保留组合键
fn cancel_pending(s: &mut State) {
    s.cancelled = true;
    s.gen += 1;
    if std::mem::take(&mut s.held_swallowed) {
        if let Some(c) = s.down_code {
            pf::inject_key(c, true);
        }
    }
}

/// 录制下一次按键：单独点按一个修饰键，或按下 修饰键+键；Esc 取消
fn record(sh: &Shared, s: &mut State, tx: &UnboundedSender<HotEvent>, e: &KeyEvent) -> bool {
    let done = |sc: Option<Shortcut>| {
        sh.recording.store(false, Ordering::Relaxed);
        let _ = tx.send(HotEvent::Recorded(sc));
    };
    match e.kind {
        KeyKind::Down => {
            let mods = e.mods & MOD_MASK;
            if pf::special(e.code) == Some(Special::Escape) && mods == 0 {
                done(None);
            } else if mods != 0 || pf::is_function_key(e.code) {
                done(Some(Shortcut { code: e.code, mods, name: pf::key_name(e) }));
            }
        }
        KeyKind::Modifier(true) => {
            if s.rec_pending.is_none() && !s.rec_multi {
                s.rec_pending = Some(e.code);
            } else {
                s.rec_pending = None;
                s.rec_multi = true;
            }
        }
        KeyKind::Modifier(false) => {
            if s.rec_pending == Some(e.code) {
                s.rec_pending = None;
                done(Some(Shortcut { code: e.code, mods: 0, name: pf::key_name(e) }));
            } else if e.mods & (MOD_MASK | pf::FN) == 0 {
                s.rec_pending = None;
                s.rec_multi = false;
            }
        }
        KeyKind::Up => {}
    }
    if !sh.recording.load(Ordering::Relaxed) {
        s.rec_pending = None;
        s.rec_multi = false;
    }
    true
}
