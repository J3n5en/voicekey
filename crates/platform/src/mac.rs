use crate::{HookFn, KeyEvent, KeyKind, MicStatus, Rect, ALT, CTRL, FN, META, SHIFT};
use core_foundation::base::{CFType, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::string::{CFString, CFStringRef};
use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::Mutex;
use std::time::Duration;

type Ref = *mut c_void;

#[repr(C)]
#[derive(Default, Clone, Copy)]
struct CGRect {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

type TapCallback = extern "C" fn(Ref, u32, Ref, Ref) -> Ref;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn CGEventTapCreate(tap: u32, place: u32, options: u32, mask: u64, cb: TapCallback, refcon: Ref) -> Ref;
    fn CGEventTapEnable(tap: Ref, enable: bool);
    fn CGEventGetIntegerValueField(e: Ref, field: u32) -> i64;
    fn CGEventSetIntegerValueField(e: Ref, field: u32, v: i64);
    fn CGEventGetFlags(e: Ref) -> u64;
    fn CGEventSetFlags(e: Ref, f: u64);
    fn CGEventKeyboardGetUnicodeString(e: Ref, max: usize, actual: *mut usize, buf: *mut u16);
    fn CGEventKeyboardSetUnicodeString(e: Ref, len: usize, buf: *const u16);
    fn CGEventCreateKeyboardEvent(src: Ref, key: u16, down: bool) -> Ref;
    fn CGEventPost(tap: u32, e: Ref);
    fn CGEventSourceCreate(state: i32) -> Ref;
    fn CFMachPortCreateRunLoopSource(alloc: Ref, port: Ref, order: isize) -> Ref;
    fn CFRunLoopGetCurrent() -> Ref;
    fn CFRunLoopAddSource(rl: Ref, src: Ref, mode: CFStringRef);
    fn CFRunLoopRun();
    fn CFRelease(p: Ref);
    static kCFRunLoopCommonModes: CFStringRef;

    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(opts: Ref) -> bool;
    fn AXUIElementCreateSystemWide() -> Ref;
    fn AXUIElementCopyAttributeValue(el: Ref, attr: CFStringRef, out: *mut Ref) -> i32;
    fn AXUIElementCopyParameterizedAttributeValue(el: Ref, attr: CFStringRef, param: Ref, out: *mut Ref) -> i32;
    fn AXUIElementSetMessagingTimeout(el: Ref, t: f32) -> i32;
    fn AXUIElementCreateApplication(pid: i32) -> Ref;
    fn AXValueCreate(kind: u32, value: *const c_void) -> Ref;
    fn AXValueGetValue(v: Ref, kind: u32, out: *mut c_void) -> bool;
    static kAXTrustedCheckOptionPrompt: CFStringRef;
}

const KEY_DOWN: u32 = 10;
const KEY_UP: u32 = 11;
const FLAGS_CHANGED: u32 = 12;
const FIELD_KEYCODE: u32 = 9;
const FIELD_AUTOREPEAT: u32 = 8;
const FIELD_USER_DATA: u32 = 42;
/// 自己注入的事件打标记，钩子里跳过
const MAGIC: i64 = 0x564B_4559;

const F_SHIFT: u64 = 0x20000;
const F_CTRL: u64 = 0x40000;
const F_ALT: u64 = 0x80000;
const F_CMD: u64 = 0x100000;
const F_FN: u64 = 0x800000;

static TAP: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
static HOOK: Mutex<Option<HookFn>> = Mutex::new(None);

fn mods(flags: u64) -> u8 {
    let mut m = 0;
    for (f, b) in [(F_CTRL, CTRL), (F_ALT, ALT), (F_SHIFT, SHIFT), (F_CMD, META), (F_FN, FN)] {
        if flags & f != 0 {
            m |= b;
        }
    }
    m
}

fn flag_of(m: u8) -> u64 {
    match m {
        CTRL => F_CTRL,
        ALT => F_ALT,
        SHIFT => F_SHIFT,
        META => F_CMD,
        _ => F_FN,
    }
}

extern "C" fn tap_cb(_proxy: Ref, kind: u32, event: Ref, _refcon: Ref) -> Ref {
    if kind == 0xFFFF_FFFE || kind == 0xFFFF_FFFF {
        let tap = TAP.load(Ordering::Relaxed);
        if !tap.is_null() {
            unsafe { CGEventTapEnable(tap, true) };
        }
        return event;
    }
    if unsafe { CGEventGetIntegerValueField(event, FIELD_USER_DATA) } == MAGIC {
        return event;
    }
    let code = unsafe { CGEventGetIntegerValueField(event, FIELD_KEYCODE) } as u32;
    let flags = unsafe { CGEventGetFlags(event) };
    let kind = match kind {
        KEY_DOWN => KeyKind::Down,
        KEY_UP => KeyKind::Up,
        FLAGS_CHANGED => match keys::modifier(code) {
            Some((m, _)) => KeyKind::Modifier(flags & flag_of(m) != 0),
            None => return event,
        },
        _ => return event,
    };
    let chars = (kind == KeyKind::Down).then(|| {
        let mut buf = [0u16; 8];
        let mut n = 0usize;
        unsafe { CGEventKeyboardGetUnicodeString(event, buf.len(), &mut n, buf.as_mut_ptr()) };
        String::from_utf16_lossy(&buf[..n])
    });
    let ev = KeyEvent {
        kind,
        code,
        mods: mods(flags),
        repeat: unsafe { CGEventGetIntegerValueField(event, FIELD_AUTOREPEAT) } != 0,
        chars,
    };
    let swallow = HOOK.lock().unwrap().as_mut().is_some_and(|f| f(&ev));
    if swallow { std::ptr::null_mut() } else { event }
}

/// 安装全局键盘钩子；无辅助功能权限时每 2 秒重试直到授权
pub fn start_hook(f: HookFn) {
    *HOOK.lock().unwrap() = Some(f);
    std::thread::spawn(|| loop {
        let mask = (1u64 << KEY_DOWN) | (1 << KEY_UP) | (1 << FLAGS_CHANGED);
        let tap = unsafe { CGEventTapCreate(1, 0, 0, mask, tap_cb, std::ptr::null_mut()) };
        if tap.is_null() {
            std::thread::sleep(Duration::from_secs(2));
            continue;
        }
        TAP.store(tap, Ordering::Relaxed);
        unsafe {
            let src = CFMachPortCreateRunLoopSource(std::ptr::null_mut(), tap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
            CGEventTapEnable(tap, true);
            CFRunLoopRun();
        }
    });
}

fn post_key(src: Ref, code: u16, flags: u64, unicode: Option<&[u16]>) {
    for down in [true, false] {
        unsafe {
            let e = CGEventCreateKeyboardEvent(src, code, down);
            if e.is_null() {
                continue;
            }
            CGEventSetFlags(e, flags);
            CGEventSetIntegerValueField(e, FIELD_USER_DATA, MAGIC);
            if let Some(u) = unicode {
                CGEventKeyboardSetUnicodeString(e, u.len(), u.as_ptr());
            }
            CGEventPost(0, e);
            CFRelease(e);
        }
    }
}

/// 私有事件源：不混入用户仍按着的修饰键
fn private_source() -> Ref {
    static SRC: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
    let s = SRC.load(Ordering::Relaxed);
    if !s.is_null() {
        return s;
    }
    let s = unsafe { CGEventSourceCreate(-1) };
    SRC.store(s, Ordering::Relaxed);
    s
}

pub(crate) fn backspace(n: usize) {
    for _ in 0..n {
        post_key(private_source(), 51, 0, None);
    }
}

pub(crate) fn type_text(text: &str) {
    let units: Vec<u16> = text.encode_utf16().collect();
    for chunk in units.chunks(20) {
        post_key(private_source(), 0, 0, Some(chunk));
    }
}

/// Windows 用于重放被吞掉的修饰键；macOS 不吞修饰键，无需重放
pub fn inject_key(_code: u32, _down: bool) {}

/// 借剪贴板 + ⌘V 上屏，随后恢复原剪贴板（保留所有类型）
pub fn paste(text: &str) {
    use objc2::runtime::ProtocolObject;
    use objc2_app_kit::{NSPasteboard, NSPasteboardItem, NSPasteboardTypeString, NSPasteboardWriting};
    use objc2_foundation::{NSArray, NSString};
    unsafe {
        let pb = NSPasteboard::generalPasteboard();
        let saved: Vec<_> = pb
            .pasteboardItems()
            .map(|items| {
                items
                    .iter()
                    .map(|item| {
                        let copy = NSPasteboardItem::new();
                        for t in item.types().iter() {
                            if let Some(d) = item.dataForType(&t) {
                                copy.setData_forType(&d, &t);
                            }
                        }
                        copy
                    })
                    .collect()
            })
            .unwrap_or_default();
        pb.clearContents();
        pb.setString_forType(&NSString::from_str(text), NSPasteboardTypeString);
        let change = pb.changeCount();
        post_key(CGEventSourceCreate(0), 9, F_CMD, None);
        if saved.is_empty() {
            return;
        }
        let objs: Vec<_> = saved.into_iter().map(ProtocolObject::<dyn NSPasteboardWriting>::from_retained).collect();
        let arr = NSArray::from_retained_slice(&objs);
        let restore = SendPtr(objc2::rc::Retained::into_raw(arr) as *mut c_void);
        std::thread::spawn(move || {
            let restore = restore;
            std::thread::sleep(Duration::from_millis(500));
            let arr: objc2::rc::Retained<NSArray<ProtocolObject<dyn NSPasteboardWriting>>> =
                objc2::rc::Retained::from_raw(restore.0 as *mut _).unwrap();
            let pb = NSPasteboard::generalPasteboard();
            if pb.changeCount() == change {
                pb.clearContents();
                pb.writeObjects(&arr);
            }
        });
    }
}

struct SendPtr(*mut c_void);
unsafe impl Send for SendPtr {}

fn ax_rect(v: Ref, kind: u32) -> Option<CGRect> {
    let mut r = CGRect::default();
    let ok = unsafe {
        match kind {
            3 => AXValueGetValue(v, 3, &mut r as *mut _ as *mut c_void),
            _ => {
                let mut pt = [0f64; 2];
                let ok = AXValueGetValue(v, kind, pt.as_mut_ptr() as *mut c_void);
                if kind == 1 { (r.x, r.y) = (pt[0], pt[1]) } else { (r.w, r.h) = (pt[0], pt[1]) }
                ok
            }
        }
    };
    ok.then_some(r)
}

fn ax_attr(el: Ref, name: &str) -> Option<CFType> {
    let attr = CFString::new(name);
    let mut out: Ref = std::ptr::null_mut();
    let err = unsafe { AXUIElementCopyAttributeValue(el, attr.as_concrete_TypeRef(), &mut out) };
    (err == 0 && !out.is_null()).then(|| unsafe { CFType::wrap_under_create_rule(out as _) })
}

/// 当前输入焦点的选区（或控件）屏幕坐标，原点左上，单位逻辑点
pub fn caret() -> Option<Rect> {
    unsafe {
        let el = focused_element()?;
        let el = el.as_CFTypeRef() as Ref;
        let frame = (|| {
            let pos = ax_rect(ax_attr(el, "AXPosition")?.as_CFTypeRef() as Ref, 1)?;
            let size = ax_rect(ax_attr(el, "AXSize")?.as_CFTypeRef() as Ref, 2)?;
            Some(CGRect { x: pos.x, y: pos.y, w: size.w, h: size.h })
        })();
        // 有些应用（如 Qt 系 Telegram 客户端）空输入时返回 (0,0,1,0) 这类无效矩形：只接受落在输入框内、有高度的结果
        let valid = |r: &CGRect| {
            r.h > 0.0
                && frame.is_none_or(|f| r.x >= f.x - 4.0 && r.x <= f.x + f.w + 4.0 && r.y >= f.y - 4.0 && r.y <= f.y + f.h + 4.0)
        };
        if let Some(range) = ax_attr(el, "AXSelectedTextRange") {
            if let Some(r) = bounds_for(el, range.as_CFTypeRef() as Ref).filter(valid) {
                return Some(Rect { x: r.x, y: r.y, w: r.w, h: r.h, physical: false });
            }
            // 插入点本身取不到时，用前一个字符的右边缘
            let mut cr = [0isize; 2];
            if AXValueGetValue(range.as_CFTypeRef() as Ref, 4, cr.as_mut_ptr() as *mut c_void) && cr[1] == 0 && cr[0] > 0 {
                let prev = [cr[0] - 1, 1isize];
                let v = AXValueCreate(4, prev.as_ptr() as *const c_void);
                if !v.is_null() {
                    let v = CFType::wrap_under_create_rule(v as _);
                    if let Some(r) = bounds_for(el, v.as_CFTypeRef() as Ref).filter(valid) {
                        return Some(Rect { x: r.x + r.w, y: r.y, w: 0.0, h: r.h, physical: false });
                    }
                }
            }
        }
        // 退回输入框本身：取其左上角一行高度，面板贴着输入框上沿
        let f = frame.filter(|f| f.w > 0.0 && f.h > 0.0)?;
        Some(Rect { x: f.x + 8.0, y: f.y, w: 0.0, h: f.h.min(22.0), physical: false })
    }
}

unsafe fn bounds_for(el: Ref, range: Ref) -> Option<CGRect> {
    let attr = CFString::new("AXBoundsForRange");
    let mut out: Ref = std::ptr::null_mut();
    if AXUIElementCopyParameterizedAttributeValue(el, attr.as_concrete_TypeRef(), range, &mut out) != 0 || out.is_null() {
        return None;
    }
    let v = CFType::wrap_under_create_rule(out as _);
    ax_rect(v.as_CFTypeRef() as Ref, 3)
}

/// 系统级焦点查询对部分应用（如 iMe/Telegram）返回空，退回按前台应用 pid 查询
unsafe fn focused_element() -> Option<CFType> {
    let sys = CFType::wrap_under_create_rule(AXUIElementCreateSystemWide() as _);
    AXUIElementSetMessagingTimeout(sys.as_CFTypeRef() as Ref, 0.3);
    if let Some(el) = ax_attr(sys.as_CFTypeRef() as Ref, "AXFocusedUIElement") {
        return Some(el);
    }
    let pid = front_app()?.0;
    let app = CFType::wrap_under_create_rule(AXUIElementCreateApplication(pid) as _);
    AXUIElementSetMessagingTimeout(app.as_CFTypeRef() as Ref, 0.3);
    ax_attr(app.as_CFTypeRef() as Ref, "AXFocusedUIElement")
}

/// 前台应用（按 pid 记录，便于跨线程）
#[derive(Clone, Copy, Debug)]
pub struct FrontApp(i32);

#[link(name = "Carbon", kind = "framework")]
extern "C" {
    fn IsSecureEventInputEnabled() -> u8;
}

/// 有 App 开启了安全输入：事件钩子收不到 keyDown（只剩修饰键）
pub fn secure_input() -> bool {
    unsafe { IsSecureEventInputEnabled() != 0 }
}

pub fn front_app() -> Option<FrontApp> {
    use objc2_app_kit::NSWorkspace;
    let app = NSWorkspace::sharedWorkspace().frontmostApplication()?;
    Some(FrontApp(app.processIdentifier()))
}

impl FrontApp {
    pub fn activate(&self) {
        use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication};
        if let Some(app) = NSRunningApplication::runningApplicationWithProcessIdentifier(self.0) {
            app.activateWithOptions(NSApplicationActivationOptions::empty());
        }
    }
}

pub mod perm {
    use super::*;

    pub fn accessibility(prompt: bool) -> bool {
        if !prompt {
            return unsafe { AXIsProcessTrusted() };
        }
        let key = unsafe { CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt) };
        let dict = CFDictionary::from_CFType_pairs(&[(key.as_CFType(), CFBoolean::true_value().as_CFType())]);
        unsafe { AXIsProcessTrustedWithOptions(dict.as_concrete_TypeRef() as Ref) }
    }

    pub fn mic() -> MicStatus {
        use objc2_av_foundation::{AVAuthorizationStatus, AVCaptureDevice, AVMediaTypeAudio};
        let Some(t) = (unsafe { AVMediaTypeAudio }) else { return MicStatus::Denied };
        match unsafe { AVCaptureDevice::authorizationStatusForMediaType(t) } {
            AVAuthorizationStatus::Authorized => MicStatus::Granted,
            AVAuthorizationStatus::NotDetermined => MicStatus::Undetermined,
            _ => MicStatus::Denied,
        }
    }

    pub fn request_mic() {
        use objc2_av_foundation::{AVCaptureDevice, AVMediaTypeAudio};
        let Some(t) = (unsafe { AVMediaTypeAudio }) else { return };
        let block = block2::RcBlock::new(|_: objc2::runtime::Bool| {});
        unsafe { AVCaptureDevice::requestAccessForMediaType_completionHandler(t, &block) };
    }

    fn open(anchor: &str) {
        let url = format!("x-apple.systempreferences:com.apple.preference.security?{anchor}");
        let _ = std::process::Command::new("open").arg(url).spawn();
    }

    pub fn open_accessibility() {
        open("Privacy_Accessibility");
    }

    pub fn open_mic() {
        open("Privacy_Microphone");
    }
}

pub mod keys {
    use crate::{HoldKey, Special, ALT, CTRL, FN, META, SHIFT};

    pub fn modifier(code: u32) -> Option<(u8, &'static str)> {
        Some(match code {
            54 => (META, "右 ⌘"),
            55 => (META, "左 ⌘"),
            58 => (ALT, "左 ⌥"),
            61 => (ALT, "右 ⌥"),
            59 => (CTRL, "左 ⌃"),
            62 => (CTRL, "右 ⌃"),
            56 => (SHIFT, "左 ⇧"),
            60 => (SHIFT, "右 ⇧"),
            63 => (FN, "Fn"),
            _ => return None,
        })
    }

    pub fn special(code: u32) -> Option<Special> {
        Some(match code {
            53 => Special::Escape,
            36 | 76 => Special::Enter,
            126 => Special::Up,
            125 => Special::Down,
            18 => Special::Digit(1),
            19 => Special::Digit(2),
            20 => Special::Digit(3),
            21 => Special::Digit(4),
            23 => Special::Digit(5),
            22 => Special::Digit(6),
            26 => Special::Digit(7),
            28 => Special::Digit(8),
            25 => Special::Digit(9),
            _ => return None,
        })
    }

    const FKEYS: [u32; 20] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90];

    /// 不带修饰键也允许单独使用的键（F1–F20）
    pub fn is_function_key(code: u32) -> bool {
        FKEYS.contains(&code)
    }

    pub fn special_name(code: u32) -> Option<&'static str> {
        const F: [&str; 20] = ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12", "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20"];
        if let Some(i) = FKEYS.iter().position(|&c| c == code) {
            return Some(F[i]);
        }
        Some(match code {
            49 => "Space",
            36 => "↩",
            48 => "⇥",
            51 => "⌫",
            117 => "⌦",
            53 => "⎋",
            123 => "←",
            124 => "→",
            125 => "↓",
            126 => "↑",
            115 => "Home",
            119 => "End",
            116 => "PgUp",
            121 => "PgDn",
            _ => return None,
        })
    }

    pub fn hold_keys() -> &'static [HoldKey] {
        &[
            HoldKey { id: "rightAlt", code: 61, name: "右 ⌥" },
            HoldKey { id: "rightMeta", code: 54, name: "右 ⌘" },
            HoldKey { id: "rightCtrl", code: 62, name: "右 ⌃" },
            HoldKey { id: "fn", code: 63, name: "Fn" },
        ]
    }
}
