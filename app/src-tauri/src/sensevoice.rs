//! SenseVoice 本地识别：模型与推理脚本在本机，音频不出本机
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Runtime};
use voicekey_core::Engine;

pub use voicekey_sensevoice::installed;
use voicekey_sensevoice::{model_dir, MODEL_ENTRIES, SCRIPT};

static STATUS: Mutex<Option<Value>> = Mutex::new(None);

/// 模型来源目录：环境变量 SENSEVOICE_MODEL_SRC 优先；否则弹目录选择框让用户指定
fn pick_source_dir() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("SENSEVOICE_MODEL_SRC").map(PathBuf::from) {
        return p.is_dir().then_some(p);
    }
    rfd::FileDialog::new().set_title("选择 SenseVoiceSmall 模型目录").pick_folder()
}

pub fn engine() -> std::sync::Arc<dyn Engine> {
    std::sync::Arc::new(voicekey_sensevoice::LocalEngine)
}

pub fn status() -> Value {
    if let Some(v) = STATUS.lock().unwrap().clone() {
        return v;
    }
    json!({ "state": if installed() { "ready" } else { "missing" } })
}

fn set_status<R: Runtime>(app: &AppHandle<R>, v: Value) {
    *STATUS.lock().unwrap() = Some(v.clone());
    let _ = app.emit("model", json!({ "ch": "sensevoice", "status": v }));
}

/// 把本机已有的 SenseVoiceSmall 拷进数据目录（sentencepiece 不能读中文路径，必须落到纯英文目录）
pub fn download<R: Runtime>(app: &AppHandle<R>) {
    if installed() || status()["state"] == "downloading" {
        return;
    }
    // 选目录是阻塞的，放到阻塞线程里，避免卡住 UI 线程
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let src = tauri::async_runtime::spawn_blocking(pick_source_dir).await.ok().flatten();
        let Some(src) = src else { return };
        set_status(&app, json!({ "state": "downloading", "progress": 0.0 }));
        let r = tauri::async_runtime::spawn_blocking(move || copy_all(&src)).await.unwrap_or_else(|e| Err(e.to_string()));
        set_status(&app, match r {
            Ok(()) => json!({ "state": "ready" }),
            Err(e) => json!({ "state": "failed", "error": e }),
        });
    });
}

/// 选中本地渠道时提前拉起推理进程，省掉第一句话的模型加载等待
pub fn prewarm<R: Runtime>(_app: &AppHandle<R>, s: &crate::settings::Settings) {
    let on = s.channel == crate::settings::Channel::Sensevoice
        || (s.channel == crate::settings::Channel::All && s.multi.contains(&crate::settings::Channel::Sensevoice));
    if !on || !installed() {
        return;
    }
    tauri::async_runtime::spawn(async {
        let e = engine();
        e.prewarm().await;
    });
}

fn copy_all(src: &std::path::Path) -> Result<(), String> {
    let dst = model_dir();
    std::fs::create_dir_all(&dst).map_err(|e| format!("创建目录失败：{e}"))?;
    for name in MODEL_ENTRIES {
        let from = src.join(name);
        if !from.is_file() {
            return Err(format!("{name} 不存在，模型目录不完整"));
        }
        std::fs::copy(&from, dst.join(name)).map_err(|e| format!("复制 {name} 失败：{e}"))?;
    }
    let has_script = std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join(SCRIPT))).is_some_and(|p| p.is_file());
    if !has_script {
        return Err(format!("缺少 {SCRIPT}，请放在程序同目录"));
    }
    Ok(())
}

