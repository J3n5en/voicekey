//! 长按键：按住超过阈值开始、松开结束（单个修饰键、鼠标中键/侧键或自定义组合）。点按快捷键：单个修饰键在阈值内松开，或 组合键按下（吞掉不传给前台 App）
use crate::settings::{Combo, Shortcut};
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
    /// 长按被取消，或短按没有变成点按
    Cancel,
    Escape,
    Pick(Special),
    Recorded(Option<Shortcut>),
    RecordedHold(Option<Combo>),
}

#[derive(Default)]
pub struct Config {
    /// 单个修饰键或鼠标键长按；自定义组合时为 0
    pub hold: u32,
    pub chord: Option<Chord>,
    pub tap: Option<Shortcut>,
}

/// 长按组合：若干修饰键（区分左右）+ 至多一个普通键
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chord {
    pub mods: Vec<u32>,
    pub key: Option<u32>,
}

impl Config {
    pub fn set_hold(&mut self, codes: &[u32]) {
        (self.hold, self.chord) = match codes {
            [] => (0, None),
            // 单个鼠标键必须走长按路径。放进空修饰的 Chord 时，track() 会在任意键盘 Down 上覆盖 held_key，按住侧键时再按别的键就会结束录音。
            [c] if pf::modifier(*c).is_some() || pf::is_mouse_button(*c) => (*c, None),
            _ => {
                let (mods, keys): (Vec<u32>, Vec<u32>) = codes.iter().partition(|c| pf::modifier(**c).is_some());
                (0, Some(Chord { mods, key: keys.first().copied() }))
            }
        };
    }
}

/// 可作长按的组合：纯修饰键；单个 F 键或鼠标中键/侧键；或 修饰键+一个键（只有 Shift 时不行，否则打不了大写）
pub fn valid_hold(codes: &[u32]) -> bool {
    let keys: Vec<u32> = codes.iter().copied().filter(|c| pf::modifier(*c).is_none()).collect();
    let strong_mod = codes.iter().any(|c| pf::modifier(*c).is_some_and(|(f, _)| f != pf::SHIFT));
    match keys.as_slice() {
        [] => !codes.is_empty(),
        [k] => pf::is_function_key(*k) || pf::is_mouse_button(*k) || strong_mod,
        _ => false,
    }
}

#[derive(Default)]
pub struct Shared {
    pub config: RwLock<Config>,
    /// 候选面板打开时吞掉方向键/数字/回车/Esc
    pub picking: AtomicBool,
    /// 设置里录制快捷键
    pub recording: AtomicBool,
    /// 录制目标是长按组合（否则为点按快捷键）
    pub record_hold: AtomicBool,
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
    /// 录制长按组合：当前按住的键、本轮按过的全部键
    rec_held: Vec<(u32, String)>,
    rec_peak: Vec<(u32, String)>,
    /// 组合长按：当前按住的修饰键与普通键
    held_mods: Vec<u32>,
    held_key: Option<u32>,
    chord_on: bool,
    chord_active: bool,
}

pub fn start(shared: Arc<Shared>, tx: UnboundedSender<HotEvent>) {
    let state = Arc::new(Mutex::new(State::default()));
    pf::start_hook(Box::new(move |e| handle(&shared, &state, &tx, e)));
}

fn handle(sh: &Shared, st: &Arc<Mutex<State>>, tx: &UnboundedSender<HotEvent>, e: &KeyEvent) -> bool {
    if sh.recording.load(Ordering::Relaxed) {
        let mut s = st.lock().unwrap();
        return if sh.record_hold.load(Ordering::Relaxed) { record_hold(sh, &mut s, tx, e) } else { record(sh, &mut s, tx, e) };
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
    if let Some(c) = cfg.chord.as_ref() {
        if chord(c, &mut s, st, tx, e) {
            return true;
        }
    }
    match e.kind {
        KeyKind::Down => {
            if pf::special(e.code) == Some(Special::Escape) && !e.repeat {
                let _ = tx.send(HotEvent::Escape);
            }
            // 鼠标键没有 Modifier 事件。单独绑定时和修饰键长按一样：超过阈值才开始，一旦激活，别的键不打断，松开才结束。
            if pf::is_mouse_button(e.code) && e.code == cfg.hold {
                if s.down_code.is_none() && !e.repeat {
                    s.down_code = Some(e.code);
                    s.pressed_at = Some(Instant::now());
                    s.cancelled = false;
                    s.tapped = false;
                    s.gen += 1;
                    let _ = tx.send(HotEvent::Press);
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
                return true;
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
                cancel_pending(&mut s, tx);
            }
            false
        }
        KeyKind::Up => {
            if s.swallowed_code == Some(e.code) {
                s.swallowed_code = None;
                return true;
            }
            if s.down_code == Some(e.code) && pf::is_mouse_button(e.code) {
                let tap_code = cfg.tap.as_ref().filter(|t| pf::is_mouse_button(t.code)).map(|t| t.code);
                s.down_code = None;
                s.gen += 1;
                if s.active {
                    s.active = false;
                    let _ = tx.send(HotEvent::Release);
                } else if Some(e.code) == tap_code
                    && !s.cancelled
                    && s.pressed_at.is_some_and(|t| t.elapsed() < THRESHOLD)
                {
                    s.tapped = true;
                    let _ = tx.send(HotEvent::Tap);
                } else if !s.cancelled {
                    let _ = tx.send(HotEvent::Cancel);
                }
                return true;
            }
            false
        }
        KeyKind::Modifier(pressed) => {
            let tap_code = cfg.tap.as_ref().filter(|t| t.is_modifier()).map(|t| t.code);
            let ours = e.code == s.down_code.unwrap_or(e.code) && (e.code == cfg.hold || Some(e.code) == tap_code);
            if !ours {
                if s.down_code.is_some() && !s.active {
                    cancel_pending(&mut s, tx);
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
                let _ = tx.send(HotEvent::Cancel);
                // 普通短按：原样重放
                pf::inject_key(e.code, true);
                pf::inject_key(e.code, false);
            } else {
                let _ = tx.send(HotEvent::Cancel);
            }
            swallowed
        }
    }
}

/// 按住期间按了别的键：放弃本次长按/点按，并把吞掉的修饰键补发给系统以保留组合键
fn cancel_pending(s: &mut State, tx: &UnboundedSender<HotEvent>) {
    if s.cancelled {
        return;
    }
    s.cancelled = true;
    s.gen += 1;
    let _ = tx.send(HotEvent::Cancel);
    if std::mem::take(&mut s.held_swallowed) {
        if let Some(c) = s.down_code {
            pf::inject_key(c, true);
        }
    }
}

/// 组合长按：全部按齐（且无多余键）计时，超过阈值开始；任一组合键松开即结束。返回 true 吞掉组合里的普通键
fn chord(c: &Chord, s: &mut State, st: &Arc<Mutex<State>>, tx: &UnboundedSender<HotEvent>, e: &KeyEvent) -> bool {
    track(s, e);
    let exact = s.held_key == c.key && s.held_mods.len() == c.mods.len() && c.mods.iter().all(|m| s.held_mods.contains(m));
    let kept = c.mods.iter().all(|m| s.held_mods.contains(m)) && (c.key.is_none() || s.held_key == c.key);
    // 含普通键时只在该键按下那一刻开始，避免先按键再按修饰键时误触
    let starts = c.key.is_none() || (e.kind == KeyKind::Down && Some(e.code) == c.key && !e.repeat);
    if !s.chord_on && exact && starts {
        if s.down_code.is_some() && !s.active {
            cancel_pending(s, tx);
        }
        s.chord_on = true;
        s.gen += 1;
        let _ = tx.send(HotEvent::Press);
        let (gen, st, tx) = (s.gen, st.clone(), tx.clone());
        std::thread::spawn(move || {
            std::thread::sleep(THRESHOLD);
            let mut s = st.lock().unwrap();
            if s.gen == gen && s.chord_on {
                s.chord_active = true;
                let _ = tx.send(HotEvent::LongPress);
            }
        });
    } else if s.chord_on && !(if s.chord_active { kept } else { exact }) {
        s.chord_on = false;
        s.gen += 1;
        let _ = tx.send(if std::mem::take(&mut s.chord_active) { HotEvent::Release } else { HotEvent::Cancel });
    }
    if s.chord_on && e.kind == KeyKind::Down && Some(e.code) == c.key {
        s.swallowed_code = Some(e.code);
        return true;
    }
    false
}

fn track(s: &mut State, e: &KeyEvent) {
    match e.kind {
        KeyKind::Modifier(down) => {
            if pf::modifier(e.code).is_none() {
                return;
            }
            s.held_mods.retain(|&c| c != e.code);
            if down {
                s.held_mods.push(e.code);
            } else if e.mods & (MOD_MASK | pf::FN) == 0 {
                s.held_mods.clear();
            }
        }
        KeyKind::Down => {
            // 以当前标志位纠正漏掉的修饰键松开
            s.held_mods.retain(|&c| pf::modifier(c).is_some_and(|(f, _)| e.mods & f != 0));
            if !e.repeat {
                s.held_key = Some(e.code);
            }
        }
        KeyKind::Up => {
            if s.held_key == Some(e.code) {
                s.held_key = None;
            }
        }
    }
}

/// 录制下一次按键：单独点按一个修饰键，或按下 修饰键+键、F 键、鼠标中键/侧键；Esc 取消
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
            } else if mods != 0 || pf::is_function_key(e.code) || pf::is_mouse_button(e.code) {
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

/// 录制长按组合：按住一组键，松开任意一个时记录本轮按过的全部键；不合法则继续等待。Esc 取消
fn record_hold(sh: &Shared, s: &mut State, tx: &UnboundedSender<HotEvent>, e: &KeyEvent) -> bool {
    let is_mod = pf::modifier(e.code).is_some();
    match e.kind {
        KeyKind::Down if e.repeat => {}
        KeyKind::Down if s.rec_held.is_empty() && pf::special(e.code) == Some(Special::Escape) => {
            sh.recording.store(false, Ordering::Relaxed);
            let _ = tx.send(HotEvent::RecordedHold(None));
        }
        KeyKind::Down | KeyKind::Modifier(true) if is_mod == (e.kind != KeyKind::Down) => {
            if !s.rec_held.iter().any(|(c, _)| *c == e.code) {
                let k = (e.code, pf::key_name(e));
                if !s.rec_peak.iter().any(|(c, _)| *c == e.code) {
                    s.rec_peak.push(k.clone());
                }
                s.rec_held.push(k);
            }
        }
        KeyKind::Up | KeyKind::Modifier(false) => {
            s.rec_held.retain(|(c, _)| *c != e.code);
            let mut peak = std::mem::take(&mut s.rec_peak);
            peak.sort_by_key(|(c, _)| pf::modifier(*c).is_none());
            let codes: Vec<u32> = peak.iter().map(|(c, _)| *c).collect();
            if valid_hold(&codes) {
                let name = peak.into_iter().map(|(_, n)| n).collect::<Vec<_>>().join(" + ");
                sh.recording.store(false, Ordering::Relaxed);
                let _ = tx.send(HotEvent::RecordedHold(Some(Combo { codes, name })));
            } else {
                s.rec_peak = s.rec_held.clone();
            }
        }
        _ => {}
    }
    if !sh.recording.load(Ordering::Relaxed) {
        s.rec_held.clear();
        s.rec_peak.clear();
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(kind: KeyKind, code: u32, mods: u8) -> KeyEvent {
        KeyEvent { kind, code, mods, repeat: false, chars: None }
    }

    fn mod_code(flag: u8) -> u32 {
        (0..256).find(|&c| pf::modifier(c).is_some_and(|(f, _)| f == flag)).unwrap()
    }

    fn plain_key() -> u32 {
        (0..256).find(|&c| pf::modifier(c).is_none() && !pf::is_function_key(c) && pf::special(c).is_none()).unwrap()
    }

    #[test]
    fn valid_hold_rules() {
        let (ctrl, alt, shift, k) = (mod_code(pf::CTRL), mod_code(pf::ALT), mod_code(pf::SHIFT), plain_key());
        assert!(valid_hold(&[ctrl]));
        assert!(valid_hold(&[ctrl, alt]));
        assert!(valid_hold(&[alt, k]));
        assert!(!valid_hold(&[shift, k]));
        assert!(!valid_hold(&[k]));
        assert!(!valid_hold(&[]));
        assert!(valid_hold(&[pf::MOUSE_BASE + 4]));
        assert!(valid_hold(&[ctrl, pf::MOUSE_BASE + 2]));
        assert!(!valid_hold(&[pf::MOUSE_BASE + 3, pf::MOUSE_BASE + 4]));
    }

    #[test]
    fn mouse_button_hold_long_press_and_release() {
        let side = pf::MOUSE_BASE + 4;
        let sh = Shared::default();
        {
            let mut cfg = sh.config.write().unwrap();
            cfg.set_hold(&[side]);
            assert_eq!(cfg.hold, side);
            assert!(cfg.chord.is_none());
        }
        let st = Arc::new(Mutex::new(State::default()));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let step = |e: KeyEvent| handle(&sh, &st, &tx, &e);
        assert!(step(ev(KeyKind::Down, side, 0)));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::Press)));
        std::thread::sleep(THRESHOLD + Duration::from_millis(100));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::LongPress)));
        assert!(step(ev(KeyKind::Up, side, 0)));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::Release)));
    }

    #[test]
    fn mouse_button_hold_keeps_recording_when_another_key_is_pressed() {
        let side = pf::MOUSE_BASE + 4;
        let sh = Shared::default();
        sh.config.write().unwrap().set_hold(&[side]);
        let st = Arc::new(Mutex::new(State::default()));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let step = |e: KeyEvent| handle(&sh, &st, &tx, &e);
        assert!(step(ev(KeyKind::Down, side, 0)));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::Press)));
        std::thread::sleep(THRESHOLD + Duration::from_millis(100));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::LongPress)));
        assert!(!step(ev(KeyKind::Down, plain_key(), 0)));
        assert!(rx.try_recv().is_err(), "holding the side button must keep recording");
        assert!(step(ev(KeyKind::Up, side, 0)));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::Release)));
    }

    #[test]
    fn records_mouse_button_as_tap_shortcut() {
        let sh = Shared::default();
        sh.recording.store(true, Ordering::Relaxed);
        let mut s = State::default();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        assert!(record(&sh, &mut s, &tx, &ev(KeyKind::Down, pf::MOUSE_BASE + 3, 0)));
        match rx.try_recv() {
            Ok(HotEvent::Recorded(Some(sc))) => assert_eq!(sc.code, pf::MOUSE_BASE + 3),
            other => panic!("unexpected: {other:?}"),
        }
        assert!(!sh.recording.load(Ordering::Relaxed));
    }

    #[test]
    fn chord_press_long_press_and_release() {
        let (ctrl, alt) = (mod_code(pf::CTRL), mod_code(pf::ALT));
        let (cflag, aflag) = (pf::modifier(ctrl).unwrap().0, pf::modifier(alt).unwrap().0);
        let mut cfg = Config::default();
        cfg.set_hold(&[ctrl, alt]);
        let c = cfg.chord.clone().unwrap();
        let st = Arc::new(Mutex::new(State::default()));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let step = |e: KeyEvent| chord(&c, &mut st.lock().unwrap(), &st, &tx, &e);
        step(ev(KeyKind::Modifier(true), ctrl, cflag));
        assert!(rx.try_recv().is_err());
        step(ev(KeyKind::Modifier(true), alt, cflag | aflag));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::Press)));
        std::thread::sleep(THRESHOLD + Duration::from_millis(100));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::LongPress)));
        step(ev(KeyKind::Modifier(false), alt, cflag));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::Release)));
    }

    #[test]
    fn chord_short_press_cancels_and_swallows_key() {
        let (alt, k) = (mod_code(pf::ALT), plain_key());
        let aflag = pf::modifier(alt).unwrap().0;
        let mut cfg = Config::default();
        cfg.set_hold(&[alt, k]);
        let c = cfg.chord.clone().unwrap();
        let st = Arc::new(Mutex::new(State::default()));
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let step = |e: KeyEvent| chord(&c, &mut st.lock().unwrap(), &st, &tx, &e);
        assert!(!step(ev(KeyKind::Modifier(true), alt, aflag)));
        assert!(step(ev(KeyKind::Down, k, aflag)));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::Press)));
        step(ev(KeyKind::Up, k, aflag));
        assert!(matches!(rx.try_recv(), Ok(HotEvent::Cancel)));
        std::thread::sleep(THRESHOLD + Duration::from_millis(100));
        assert!(rx.try_recv().is_err());
    }
}
