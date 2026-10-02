//! 窗口与托盘：设置窗口、胶囊浮层（hud）、候选面板（pick）
use crate::settings::{Channel, Settings};
use crate::AppState;
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::image::Image;
use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, LogicalSize, Manager, Monitor, Runtime, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

const TRAY: &[u8] = include_bytes!("../icons/tray.png");
const TRAY_ACTIVE: &[u8] = include_bytes!("../icons/tray-active.png");
const HUD_W: f64 = 680.0;
const HUD_H: f64 = 120.0;
const PICK_W: f64 = 520.0;

static HUD_TOKEN: AtomicU64 = AtomicU64::new(0);
/// 候选面板锚点（统一坐标空间：macOS 逻辑点 / Windows 物理像素）
static PICK_ANCHOR: Mutex<Option<Anchor>> = Mutex::new(None);

#[derive(Clone, Copy)]
struct Area {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    scale: f64,
}

#[derive(Clone, Copy)]
struct Anchor {
    caret: Option<(f64, f64, f64, f64)>,
    area: Area,
    height: f64,
}

fn work_area(m: &Monitor) -> Area {
    let wa = m.work_area();
    let s = m.scale_factor();
    let k = if cfg!(target_os = "macos") { s } else { 1.0 };
    Area {
        x: wa.position.x as f64 / k,
        y: wa.position.y as f64 / k,
        w: wa.size.width as f64 / k,
        h: wa.size.height as f64 / k,
        scale: s,
    }
}

/// 统一坐标空间下的尺寸换算：macOS 用逻辑点，Windows 用物理像素
fn units(a: &Area, logical: f64) -> f64 {
    if cfg!(target_os = "macos") { logical } else { logical * a.scale }
}

fn set_pos<R: Runtime>(w: &WebviewWindow<R>, x: f64, y: f64) {
    let _ = if cfg!(target_os = "macos") {
        w.set_position(tauri::LogicalPosition::new(x, y))
    } else {
        w.set_position(tauri::PhysicalPosition::new(x.round() as i32, y.round() as i32))
    };
}

fn cursor_area<R: Runtime>(app: &AppHandle<R>) -> Option<Area> {
    let p = app.cursor_position().ok();
    let m = p
        .and_then(|p| app.monitor_from_point(p.x, p.y).ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten())?;
    Some(work_area(&m))
}

fn overlay<R: Runtime>(app: &AppHandle<R>, label: &str, w: f64, h: f64) -> tauri::Result<WebviewWindow<R>> {
    WebviewWindowBuilder::new(app, label, WebviewUrl::App("index.html".into()))
        .initialization_script(format!("window.__VK_VIEW = {label:?};"))
        .title(label)
        .transparent(true)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .shadow(false)
        .visible(false)
        .focused(false)
        .focusable(false)
        .visible_on_all_workspaces(true)
        .inner_size(w, h)
        .build()
}

pub fn create_overlays<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<()> {
    overlay(app, "hud", HUD_W, HUD_H)?.set_ignore_cursor_events(true)?;
    let pick = overlay(app, "pick", PICK_W, 300.0)?;
    #[cfg(target_os = "macos")]
    panel::convert(&pick);
    #[cfg(not(target_os = "macos"))]
    let _ = pick;
    Ok(())
}

pub fn show_settings<R: Runtime>(app: &AppHandle<R>) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    let b = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .initialization_script("window.__VK_VIEW = \"settings\";")
        .title("VoiceKey 设置")
        .inner_size(860.0, 600.0)
        .resizable(false)
        .maximizable(false)
        .center();
    #[cfg(target_os = "macos")]
    let b = b.title_bar_style(tauri::TitleBarStyle::Overlay).hidden_title(true);
    let built = b.build();
    if let Ok(w) = built {
        let _ = w.set_focus();
    }
}

fn current_channel<R: Runtime>(app: &AppHandle<R>) -> Channel {
    app.state::<AppState>().settings.read().unwrap().channel
}

/// 胶囊浮层：state = listen | wait | error | info
pub fn hud<R: Runtime>(app: &AppHandle<R>, state: &str, text: &str, ch: Channel) {
    HUD_TOKEN.fetch_add(1, Ordering::Relaxed);
    let _ = app.emit_to("hud", "hud", json!({ "state": state, "text": text, "channel": ch }));
    let Some(w) = app.get_webview_window("hud") else { return };
    if !w.is_visible().unwrap_or(false) {
        if let Some(a) = cursor_area(app) {
            let (ww, hh) = (units(&a, HUD_W), units(&a, HUD_H));
            set_pos(&w, a.x + (a.w - ww) / 2.0, a.y + a.h - hh - units(&a, 24.0));
        }
        let _ = w.show();
    }
}

pub fn hud_error<R: Runtime>(app: &AppHandle<R>, msg: &str) {
    hud(app, "error", msg, current_channel(app));
    hud_hide(app, 2500);
}

pub fn hud_hide<R: Runtime>(app: &AppHandle<R>, delay_ms: u64) {
    let token = HUD_TOKEN.load(Ordering::Relaxed);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        if HUD_TOKEN.load(Ordering::Relaxed) != token {
            return;
        }
        let _ = app.emit_to("hud", "hud", json!({ "state": "hidden" }));
        tokio::time::sleep(Duration::from_millis(160)).await;
        if HUD_TOKEN.load(Ordering::Relaxed) == token {
            if let Some(w) = app.get_webview_window("hud") {
                let _ = w.hide();
            }
        }
    });
}

fn caret_in_space<R: Runtime>(app: &AppHandle<R>, r: voicekey_platform::Rect) -> Option<((f64, f64, f64, f64), Area)> {
    let mons = app.available_monitors().ok()?;
    mons.iter().find_map(|m| {
        let s = m.scale_factor();
        let (px, py) = (m.position().x as f64, m.position().y as f64);
        let (pw, ph) = (m.size().width as f64, m.size().height as f64);
        let (bx, by, bw, bh) = if r.physical { (px, py, pw, ph) } else { (px / s, py / s, pw / s, ph / s) };
        let inside = r.x >= bx && r.x < bx + bw && r.y >= by && r.y < by + bh;
        inside.then(|| ((r.x, r.y, r.w, r.h), work_area(m)))
    })
}

fn place_pick<R: Runtime>(w: &WebviewWindow<R>, a: &Anchor) {
    let ar = &a.area;
    let (pw, ph) = (units(ar, PICK_W), units(ar, a.height));
    let gap = units(ar, 6.0);
    let (x, y) = match a.caret {
        Some((cx, cy, _, chh)) => {
            let above = cy - ph - gap;
            (cx - units(ar, 40.0), if above >= ar.y { above } else { cy + chh + gap })
        }
        None => (ar.x + (ar.w - pw) / 2.0, ar.y + ar.h - ph - units(ar, 120.0)),
    };
    let x = x.clamp(ar.x + gap, (ar.x + ar.w - pw - gap).max(ar.x));
    let y = y.clamp(ar.y + gap, (ar.y + ar.h - ph - gap).max(ar.y));
    let _ = w.set_size(LogicalSize::new(PICK_W, a.height));
    set_pos(w, x, y);
}

pub fn pick_show<R: Runtime>(app: &AppHandle<R>, caret: Option<voicekey_platform::Rect>, rows: usize, focus: bool) {
    let Some(w) = app.get_webview_window("pick") else { return };
    let (caret, area) = match caret.and_then(|r| caret_in_space(app, r)) {
        Some((c, a)) => (Some(c), a),
        None => match cursor_area(app) {
            Some(a) => (None, a),
            None => return,
        },
    };
    let a = Anchor { caret, area, height: 92.0 + rows as f64 * 48.0 };
    *PICK_ANCHOR.lock().unwrap() = Some(a);
    place_pick(&w, &a);
    #[cfg(target_os = "macos")]
    panel::KEYABLE.store(focus, std::sync::atomic::Ordering::Relaxed);
    let _ = w.show();
    #[cfg(not(target_os = "macos"))]
    if focus {
        let _ = w.set_focus();
    }
}

/// 前端按内容高度回报，保持底边贴着光标
pub fn pick_resize<R: Runtime>(app: &AppHandle<R>, height: f64) {
    let Some(w) = app.get_webview_window("pick") else { return };
    let mut g = PICK_ANCHOR.lock().unwrap();
    if let Some(a) = g.as_mut() {
        a.height = height;
        place_pick(&w, a);
    }
}

pub fn pick_hide<R: Runtime>(app: &AppHandle<R>) {
    if let Some(w) = app.get_webview_window("pick") {
        let _ = w.hide();
    }
}

fn tray_menu<R: Runtime>(app: &AppHandle<R>, s: &Settings, paused: bool) -> tauri::Result<Menu<R>> {
    let head = if paused {
        "已暂停监听".to_string()
    } else {
        let tap = s.tap_shortcut.as_ref().map(|t| format!(" 或点按 {}", t.title())).unwrap_or_default();
        format!("长按 {}{} 说话", s.hold_name(), tap)
    };
    let mut items: Vec<Box<dyn IsMenuItem<R>>> = vec![
        Box::new(MenuItem::with_id(app, "head", head, false, None::<&str>)?),
        Box::new(PredefinedMenuItem::separator(app)?),
    ];
    for c in Channel::available() {
        let id = format!("ch:{}", serde_json::to_value(c)?.as_str().unwrap_or(""));
        items.push(Box::new(CheckMenuItem::with_id(app, id, c.title(), true, s.channel == c, None::<&str>)?));
    }
    items.push(Box::new(PredefinedMenuItem::separator(app)?));
    items.push(Box::new(CheckMenuItem::with_id(app, "pause", "暂停监听", true, paused, None::<&str>)?));
    items.push(Box::new(MenuItem::with_id(app, "settings", "设置…", true, Some("CmdOrCtrl+,"))?));
    items.push(Box::new(PredefinedMenuItem::separator(app)?));
    items.push(Box::new(MenuItem::with_id(app, "quit", "退出 VoiceKey", true, Some("CmdOrCtrl+Q"))?));
    let refs: Vec<&dyn IsMenuItem<R>> = items.iter().map(|b| b.as_ref()).collect();
    Menu::with_items(app, &refs)
}

fn tray_icon<R: Runtime>(app: &AppHandle<R>, active: bool) -> Option<Image<'static>> {
    if cfg!(target_os = "macos") {
        Image::from_bytes(if active { TRAY_ACTIVE } else { TRAY }).ok()
    } else {
        app.default_window_icon().map(|i| i.clone().to_owned())
    }
}

pub fn build_tray<R: Runtime>(app: &AppHandle<R>, s: &Settings) -> tauri::Result<()> {
    let mut b = TrayIconBuilder::with_id("main")
        .menu(&tray_menu(app, s, false)?)
        .show_menu_on_left_click(true)
        .icon_as_template(true)
        .tooltip("VoiceKey")
        .on_menu_event(|app, ev| crate::tray_event(app, ev.id().as_ref()));
    if let Some(i) = tray_icon(app, false) {
        b = b.icon(i);
    }
    b.build(app)?;
    Ok(())
}

pub fn refresh_tray<R: Runtime>(app: &AppHandle<R>, s: &Settings, paused: bool) {
    if let (Some(t), Ok(m)) = (app.tray_by_id("main"), tray_menu(app, s, paused)) {
        let _ = t.set_menu(Some(m));
    }
}

pub fn set_tray_active<R: Runtime>(app: &AppHandle<R>, active: bool) {
    if !cfg!(target_os = "macos") {
        return;
    }
    if let Some(t) = app.tray_by_id("main") {
        let _ = t.set_icon(tray_icon(app, active));
        let _ = t.set_icon_as_template(true);
    }
}

/// macOS：候选面板换成不激活应用的 NSPanel。需要接收按键时（安全输入）成为 key window，
/// 键盘事件直达面板而前台应用保持激活；其余时候不抢键盘。
#[cfg(target_os = "macos")]
mod panel {
    use objc2::runtime::{AnyClass, AnyObject, Bool, ClassBuilder, Sel};
    use objc2::{msg_send, sel};
    use std::sync::atomic::{AtomicBool, Ordering};
    use tauri::{Runtime, WebviewWindow};

    pub static KEYABLE: AtomicBool = AtomicBool::new(false);
    const NONACTIVATING: usize = 1 << 7;

    extern "C" {
        fn object_setClass(obj: *mut AnyObject, cls: *const AnyClass) -> *const AnyClass;
    }

    extern "C-unwind" fn can_key(_: &AnyObject, _: Sel) -> Bool {
        Bool::new(KEYABLE.load(Ordering::Relaxed))
    }

    extern "C-unwind" fn no(_: &AnyObject, _: Sel) -> Bool {
        Bool::NO
    }

    fn class() -> &'static AnyClass {
        if let Some(c) = AnyClass::get(c"VKPanel") {
            return c;
        }
        let mut b = ClassBuilder::new(c"VKPanel", AnyClass::get(c"NSPanel").unwrap()).unwrap();
        unsafe {
            b.add_method(sel!(canBecomeKeyWindow), can_key as extern "C-unwind" fn(_, _) -> _);
            b.add_method(sel!(canBecomeMainWindow), no as extern "C-unwind" fn(_, _) -> _);
        }
        b.register()
    }

    pub fn convert<R: Runtime>(w: &WebviewWindow<R>) {
        let Ok(ptr) = w.ns_window() else { return };
        let ptr = ptr as usize;
        let _ = w.run_on_main_thread(move || unsafe {
            let obj = ptr as *mut AnyObject;
            object_setClass(obj, class());
            let o = &*obj;
            let mask: usize = msg_send![o, styleMask];
            let _: () = msg_send![o, setStyleMask: mask | NONACTIVATING];
            let _: () = msg_send![o, setHidesOnDeactivate: Bool::NO];
            let _: () = msg_send![o, setHasShadow: Bool::NO];
        });
    }
}
