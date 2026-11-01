#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod controller;
mod hotkey;
mod offline;
mod settings;
mod ui;
mod update;
mod wtoffline;

use controller::Msg;
use hotkey::Shared;
use serde_json::json;
use settings::{Channel, Settings};
use std::sync::atomic::Ordering;
use std::sync::{Arc, RwLock};
use tauri::{AppHandle, Emitter, Manager, RunEvent, Runtime, WindowEvent};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};
use tokio::sync::mpsc::{self, UnboundedSender};
use voicekey_core::QwenEngine;
use voicekey_platform::{self as pf, perm, MicStatus};

pub struct AppState {
    pub settings: Arc<RwLock<Settings>>,
    pub hk: Arc<Shared>,
    pub tx: UnboundedSender<Msg>,
    pub qwen: Arc<QwenEngine>,
}

fn apply<R: Runtime>(app: &AppHandle<R>, s: &Settings) {
    let st = app.state::<AppState>();
    {
        let mut c = st.hk.config.write().unwrap();
        c.set_hold(&s.hold_codes());
        c.tap = s.tap_shortcut.clone();
    }
    ui::refresh_tray(app, s, st.hk.paused.load(Ordering::Relaxed));
    let al = app.autolaunch();
    if al.is_enabled().unwrap_or(false) != s.autostart {
        let _ = if s.autostart { al.enable() } else { al.disable() };
    }
}

pub fn update_settings<R: Runtime>(app: &AppHandle<R>, f: impl FnOnce(&mut Settings)) {
    let s = {
        let st = app.state::<AppState>();
        let mut g = st.settings.write().unwrap();
        f(&mut g);
        g.sanitize();
        g.save();
        g.clone()
    };
    apply(app, &s);
    download_model(app, s.channel);
    let _ = app.emit("settings", &s);
}

/// 本地模型渠道：开始下载（已下载或下载中则忽略）
fn download_model<R: Runtime>(app: &AppHandle<R>, ch: Channel) {
    match ch {
        Channel::Offline => offline::download(app),
        Channel::WetypeOffline => wtoffline::download(app),
        _ => {}
    }
}

pub fn model_ready(ch: Channel) -> bool {
    match ch {
        Channel::Offline => offline::installed(),
        Channel::WetypeOffline => wtoffline::installed(),
        _ => true,
    }
}

pub fn tray_event<R: Runtime>(app: &AppHandle<R>, id: &str) {
    match id {
        "settings" => ui::show_settings(app),
        "update" => update::install(app),
        "quit" => app.exit(0),
        "pause" => {
            let st = app.state::<AppState>();
            let p = !st.hk.paused.load(Ordering::Relaxed);
            st.hk.paused.store(p, Ordering::Relaxed);
            let s = st.settings.read().unwrap().clone();
            ui::refresh_tray(app, &s, p);
        }
        _ => {
            if let Some(ch) = id.strip_prefix("ch:").and_then(|c| serde_json::from_value::<Channel>(json!(c)).ok()) {
                update_settings(app, |s| s.channel = ch);
            }
        }
    }
}

fn send(app: &AppHandle, m: Msg) {
    let _ = app.state::<AppState>().tx.send(m);
}

fn perms() -> serde_json::Value {
    let mic = match perm::mic() {
        MicStatus::Granted => "granted",
        MicStatus::Denied => "denied",
        MicStatus::Undetermined => "undetermined",
    };
    json!({ "accessibility": perm::accessibility(false), "mic": mic })
}

#[tauri::command]
fn get_state(app: AppHandle) -> serde_json::Value {
    let s = app.state::<AppState>().settings.read().unwrap().clone();
    let hold: Vec<_> = pf::hold_keys().iter().map(|k| json!({ "id": k.id, "name": k.name })).collect();
    json!({
        "settings": s,
        "platform": if cfg!(target_os = "macos") { "mac" } else { "win" },
        "arch": std::env::consts::ARCH,
        "version": app.package_info().version.to_string(),
        "holdKeys": hold,
        "channels": Channel::available(),
        "offline": { "supported": offline::SUPPORTED },
        "models": { "offline": offline::status(), "wetypeoffline": wtoffline::status() },
        "perms": perms(),
        "update": update::status(),
    })
}

#[tauri::command]
fn set_settings(app: AppHandle, mut settings: Settings) {
    // 先归一化外部输入，持久化值和发给音量 worker 的值必须完全一致。
    settings.sanitize();
    let new_ducking = settings.lower_system_volume;
    let new_ducking_percent = settings.lower_system_volume_percent;
    let (mic_changed, ducking_changed) = {
        let state = app.state::<AppState>();
        let current = state.settings.read().unwrap();
        (
            current.mic != settings.mic,
            current.lower_system_volume != new_ducking
                || current.lower_system_volume_percent != new_ducking_percent,
        )
    };
    update_settings(&app, |s| *s = settings);
    if mic_changed {
        send(&app, Msg::RefreshMeter);
    }
    if ducking_changed {
        // 开关或比例在录音中修改都立即生效；非录音状态只更新下次使用的参数。
        send(&app, Msg::VolumeDucking { enabled: new_ducking, reduction_percent: new_ducking_percent });
    }
}

#[tauri::command]
fn perm_status() -> serde_json::Value {
    perms()
}

#[tauri::command]
fn perm_action(kind: String) {
    match kind.as_str() {
        "accessibility" => {
            perm::accessibility(true);
            perm::open_accessibility();
        }
        "mic-request" => perm::request_mic(),
        "mic" => perm::open_mic(),
        _ => {}
    }
}

#[tauri::command]
fn model_download(app: AppHandle, ch: Channel) {
    download_model(&app, ch);
}

#[tauri::command]
fn microphones() -> Vec<String> {
    voicekey_core::audio::microphones()
}

#[tauri::command]
fn record_shortcut(app: AppHandle, on: bool, hold: Option<bool>) {
    let hk = &app.state::<AppState>().hk;
    hk.record_hold.store(hold.unwrap_or(false), Ordering::Relaxed);
    hk.recording.store(on, Ordering::Relaxed);
}

#[tauri::command]
fn pick_choose(app: AppHandle, index: usize) {
    send(&app, Msg::PickChoose(index));
}

#[tauri::command]
fn pick_key(app: AppHandle, key: String) {
    use voicekey_platform::Special;
    let k = match key.as_str() {
        "ArrowUp" => Special::Up,
        "ArrowDown" => Special::Down,
        "Enter" => Special::Enter,
        "Escape" => Special::Escape,
        d => match d.parse::<u8>() {
            Ok(n @ 1..=9) => Special::Digit(n),
            _ => return,
        },
    };
    send(&app, Msg::PickKey(k));
}

#[tauri::command]
fn pick_resize(app: AppHandle, height: f64) {
    ui::pick_resize(&app, height);
}

#[tauri::command]
fn compare_toggle(app: AppHandle) {
    send(&app, Msg::CompareToggle);
}

#[tauri::command]
fn meter(app: AppHandle, on: bool) {
    send(&app, Msg::Meter(on));
}

#[tauri::command]
fn open_url(url: String) {
    let cmd = if cfg!(target_os = "macos") { "open" } else { "explorer" };
    let _ = std::process::Command::new(cmd).arg(url).spawn();
}

#[tauri::command]
fn update_check(app: AppHandle) {
    update::check(&app, true);
}

#[tauri::command]
fn update_install(app: AppHandle) {
    update::install(&app);
}

/// 设置页「测试」按钮：用固定的两条示例转写真打一次 Jev，返回选中项与脱敏 key
#[tauri::command]
async fn jev_test(config: voicekey_core::jev::Config) -> Result<voicekey_core::jev::Tested, String> {
    voicekey_core::jev::test(&config).await.map_err(|e| e.to_string())
}

fn main() {
    if let Some(code) = offline::worker_main() {
        std::process::exit(code);
    }
    let settings = Settings::load();
    let first_run = !settings.onboarded;
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| ui::show_settings(app)))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            get_state, set_settings, perm_status, perm_action, microphones, record_shortcut,
            pick_choose, pick_key, pick_resize, compare_toggle, meter, open_url, model_download,
            update_check, update_install, jev_test
        ])
        .setup(move |app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let (tx, rx) = mpsc::unbounded_channel();
            let qwen = Arc::new(QwenEngine::default());
            let hk = Arc::new(Shared::default());
            app.manage(AppState { settings: Arc::new(RwLock::new(settings.clone())), hk: hk.clone(), tx: tx.clone(), qwen: qwen.clone() });

            let (htx, mut hrx) = mpsc::unbounded_channel();
            hotkey::start(hk, htx);
            tauri::async_runtime::spawn(async move {
                while let Some(e) = hrx.recv().await {
                    let _ = tx.send(Msg::Hot(e));
                }
            });
            let handle = app.handle().clone();
            controller::spawn(handle.clone(), qwen, rx);
            let audio_tx = handle.state::<AppState>().tx.clone();
            voicekey_core::audio::watch_microphones(move |mics| {
                let _ = audio_tx.send(Msg::MicrophonesChanged(mics));
            });
            ui::create_overlays(&handle)?;
            ui::build_tray(&handle, &settings)?;
            apply(&handle, &settings);
            if first_run || !perm::accessibility(false) {
                ui::show_settings(&handle);
            }
            update::schedule(&handle);
            Ok(())
        })
        .on_window_event(|w, e| {
            // 先禁用电平表，再结束 Compare，避免回到 Idle 时 refresh_meter 瞬间重开麦。
            if w.label() == "main" && matches!(e, WindowEvent::Destroyed | WindowEvent::CloseRequested { .. }) {
                let st = w.state::<AppState>();
                let _ = st.tx.send(Msg::Meter(false));
                let _ = st.tx.send(Msg::CompareStop);
                st.hk.recording.store(false, Ordering::Relaxed);
            }
        })
        .build(tauri::generate_context!())
        .expect("failed to build app")
        .run(|app, e| match e {
            #[cfg(target_os = "macos")]
            RunEvent::Reopen { .. } => ui::show_settings(app),
            RunEvent::ExitRequested { api, code: None, .. } => api.prevent_exit(),
            _ => {}
        });
}
