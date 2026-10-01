use crate::{HookFn, KeyEvent, KeyKind, MicStatus, Rect, ALT, CTRL, META, SHIFT};
use std::sync::Mutex;
use std::time::Duration;
use windows::core::Interface;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::ClientToScreen;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_APARTMENTTHREADED};
use windows::Win32::System::DataExchange::GetClipboardSequenceNumber;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Variant::VARIANT;
use windows::Win32::UI::Accessibility::{AccessibleObjectFromWindow, IAccessible};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    MapVirtualKeyW, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    KEYEVENTF_UNICODE, MAPVK_VK_TO_CHAR, VIRTUAL_KEY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetForegroundWindow, GetGUIThreadInfo, GetMessageW, GetWindowThreadProcessId,
    SetForegroundWindow, SetWindowsHookExW, TranslateMessage, GUITHREADINFO, HC_ACTION, KBDLLHOOKSTRUCT, MSG,
    WH_KEYBOARD_LL, WM_KEYDOWN, WM_SYSKEYDOWN,
};

/// 自己注入的事件打标记（dwExtraInfo），钩子里跳过
const MAGIC: usize = 0x564B_4559;

struct State {
    hook: Option<HookFn>,
    down: [bool; 256],
}

static STATE: Mutex<State> = Mutex::new(State { hook: None, down: [false; 256] });

fn mods(down: &[bool; 256]) -> u8 {
    let mut m = 0;
    for (vks, b) in [([0xA2, 0xA3], CTRL), ([0xA4, 0xA5], ALT), ([0xA0, 0xA1], SHIFT), ([0x5B, 0x5C], META)] {
        if vks.iter().any(|&v| down[v]) {
            m |= b;
        }
    }
    m
}

unsafe extern "system" fn ll_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let k = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        if k.dwExtraInfo != MAGIC && k.vkCode < 256 {
            let msg = wparam.0 as u32;
            let pressed = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            let vk = k.vkCode as usize;
            let mut st = STATE.lock().unwrap();
            let repeat = pressed && st.down[vk];
            st.down[vk] = pressed;
            let is_mod = keys::modifier(k.vkCode).is_some();
            let kind = if is_mod { KeyKind::Modifier(pressed) } else if pressed { KeyKind::Down } else { KeyKind::Up };
            let chars = (kind == KeyKind::Down).then(|| {
                let c = MapVirtualKeyW(k.vkCode, MAPVK_VK_TO_CHAR) & 0x7FFF;
                char::from_u32(c).map(String::from).unwrap_or_default()
            });
            let ev = KeyEvent { kind, code: k.vkCode, mods: mods(&st.down), repeat, chars };
            if let Some(f) = st.hook.as_mut() {
                if f(&ev) {
                    return LRESULT(1);
                }
            }
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

pub fn start_hook(f: HookFn) {
    STATE.lock().unwrap().hook = Some(f);
    std::thread::spawn(|| unsafe {
        let module = GetModuleHandleW(None).ok();
        if SetWindowsHookExW(WH_KEYBOARD_LL, Some(ll_proc), module.map(Into::into), 0).is_err() {
            return;
        }
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    });
}

fn key_input(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: MAGIC },
        },
    }
}

fn send(inputs: &[INPUT]) {
    if !inputs.is_empty() {
        unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    }
}

pub fn inject_key(code: u32, down: bool) {
    let flags = if down { KEYBD_EVENT_FLAGS(0) } else { KEYEVENTF_KEYUP };
    send(&[key_input(code as u16, 0, flags)]);
}

pub(crate) fn backspace(n: usize) {
    let inputs: Vec<INPUT> = (0..n)
        .flat_map(|_| [key_input(0x08, 0, KEYBD_EVENT_FLAGS(0)), key_input(0x08, 0, KEYEVENTF_KEYUP)])
        .collect();
    send(&inputs);
}

pub(crate) fn type_text(text: &str) {
    let inputs: Vec<INPUT> = text
        .encode_utf16()
        .flat_map(|u| [key_input(0, u, KEYEVENTF_UNICODE), key_input(0, u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)])
        .collect();
    send(&inputs);
}

/// 借剪贴板 + Ctrl+V 上屏，随后恢复原剪贴板（文本/图片）
pub fn paste(text: &str) {
    let Ok(mut cb) = arboard::Clipboard::new() else {
        type_text(text);
        return;
    };
    let saved_text = cb.get_text().ok();
    let saved_image = if saved_text.is_none() { cb.get_image().ok() } else { None };
    if cb.set_text(text).is_err() {
        type_text(text);
        return;
    }
    let seq = unsafe { GetClipboardSequenceNumber() };
    send(&[
        key_input(0x11, 0, KEYBD_EVENT_FLAGS(0)),
        key_input(0x56, 0, KEYBD_EVENT_FLAGS(0)),
        key_input(0x56, 0, KEYEVENTF_KEYUP),
        key_input(0x11, 0, KEYEVENTF_KEYUP),
    ]);
    if saved_text.is_none() && saved_image.is_none() {
        return;
    }
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(500));
        if unsafe { GetClipboardSequenceNumber() } != seq {
            return;
        }
        if let Ok(mut cb) = arboard::Clipboard::new() {
            if let Some(t) = saved_text {
                let _ = cb.set_text(t);
            } else if let Some(i) = saved_image {
                let _ = cb.set_image(i);
            }
        }
    });
}

/// 当前输入焦点的插入符屏幕坐标（物理像素）：先取 Win32 caret，再取 MSAA caret（Chromium 等）
pub fn caret() -> Option<Rect> {
    unsafe {
        let fg = GetForegroundWindow();
        let tid = GetWindowThreadProcessId(fg, None);
        let mut gti = GUITHREADINFO { cbSize: std::mem::size_of::<GUITHREADINFO>() as u32, ..Default::default() };
        if GetGUIThreadInfo(tid, &mut gti).is_ok() && !gti.hwndCaret.is_invalid() {
            let r = gti.rcCaret;
            let mut p = POINT { x: r.left, y: r.top };
            if (r.right - r.left) + (r.bottom - r.top) > 0 && ClientToScreen(gti.hwndCaret, &mut p).as_bool() {
                return Some(Rect {
                    x: p.x as f64, y: p.y as f64,
                    w: (r.right - r.left) as f64, h: (r.bottom - r.top) as f64, physical: true,
                });
            }
        }
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let hwnd = if gti.hwndFocus.is_invalid() { fg } else { gti.hwndFocus };
        let mut ptr = std::ptr::null_mut();
        AccessibleObjectFromWindow(hwnd, 0xFFFF_FFF8, &IAccessible::IID, &mut ptr).ok()?;
        let acc = IAccessible::from_raw(ptr);
        let (mut x, mut y, mut w, mut h) = (0, 0, 0, 0);
        acc.accLocation(&mut x, &mut y, &mut w, &mut h, &VARIANT::from(0i32)).ok()?;
        (w + h > 0).then_some(Rect { x: x as f64, y: y as f64, w: w as f64, h: h as f64, physical: true })
    }
}

#[derive(Clone, Copy, Debug)]
pub struct FrontApp(isize);

pub fn front_app() -> Option<FrontApp> {
    let h = unsafe { GetForegroundWindow() };
    (!h.is_invalid()).then_some(FrontApp(h.0 as isize))
}

impl FrontApp {
    pub fn activate(&self) {
        unsafe {
            let _ = SetForegroundWindow(HWND(self.0 as *mut _));
        }
    }
}

pub mod perm {
    use super::MicStatus;

    pub fn accessibility(_prompt: bool) -> bool {
        true
    }
    pub fn mic() -> MicStatus {
        MicStatus::Granted
    }
    pub fn request_mic() {}
    pub fn open_accessibility() {}
    pub fn open_mic() {
        let _ = std::process::Command::new("cmd").args(["/C", "start", "ms-settings:privacy-microphone"]).spawn();
    }
}

pub mod keys {
    use crate::{HoldKey, Special, ALT, CTRL, META, SHIFT};

    pub fn modifier(code: u32) -> Option<(u8, &'static str)> {
        Some(match code {
            0xA0 => (SHIFT, "左 Shift"),
            0xA1 => (SHIFT, "右 Shift"),
            0xA2 => (CTRL, "左 Ctrl"),
            0xA3 => (CTRL, "右 Ctrl"),
            0xA4 => (ALT, "左 Alt"),
            0xA5 => (ALT, "右 Alt"),
            0x5B => (META, "左 Win"),
            0x5C => (META, "右 Win"),
            _ => return None,
        })
    }

    pub fn special(code: u32) -> Option<Special> {
        Some(match code {
            0x1B => Special::Escape,
            0x0D => Special::Enter,
            0x26 => Special::Up,
            0x28 => Special::Down,
            0x31..=0x39 => Special::Digit((code - 0x30) as u8),
            _ => return None,
        })
    }

    pub fn is_function_key(code: u32) -> bool {
        (0x70..=0x87).contains(&code)
    }

    pub fn special_name(code: u32) -> Option<&'static str> {
        const F: [&str; 24] = [
            "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
            "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20", "F21", "F22", "F23", "F24",
        ];
        if is_function_key(code) {
            return Some(F[(code - 0x70) as usize]);
        }
        Some(match code {
            0x20 => "Space",
            0x0D => "Enter",
            0x09 => "Tab",
            0x08 => "Backspace",
            0x2E => "Delete",
            0x1B => "Esc",
            0x25 => "←",
            0x27 => "→",
            0x28 => "↓",
            0x26 => "↑",
            0x24 => "Home",
            0x23 => "End",
            0x21 => "PgUp",
            0x22 => "PgDn",
            _ => return None,
        })
    }

    pub fn hold_keys() -> &'static [HoldKey] {
        &[
            HoldKey { id: "rightAlt", code: 0xA5, name: "右 Alt" },
            HoldKey { id: "rightCtrl", code: 0xA3, name: "右 Ctrl" },
            HoldKey { id: "rightShift", code: 0xA1, name: "右 Shift" },
        ]
    }
}
