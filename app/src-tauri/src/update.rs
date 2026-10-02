//! 应用内更新：GitHub Release 上的 latest.json（tauri-plugin-updater，minisign 校验）
use serde_json::{json, Value};
use std::sync::{atomic::Ordering, LazyLock, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, Runtime};
use tauri_plugin_updater::UpdaterExt;

static STATE: LazyLock<Mutex<Value>> = LazyLock::new(|| Mutex::new(json!({ "state": "idle" })));

pub fn status() -> Value {
    STATE.lock().unwrap().clone()
}

fn state() -> String {
    STATE.lock().unwrap()["state"].as_str().unwrap_or("").to_string()
}

/// 发现的新版本号（可更新时）
pub fn available() -> Option<String> {
    let s = STATE.lock().unwrap();
    (s["state"] == "available").then(|| s["version"].as_str().unwrap_or("").to_string())
}

pub fn downloading() -> bool {
    state() == "downloading"
}

fn set<R: Runtime>(app: &AppHandle<R>, v: Value) {
    let changed = std::mem::replace(&mut *STATE.lock().unwrap(), v.clone())["state"] != v["state"];
    let _ = app.emit("update", &v);
    if changed {
        let st = app.state::<crate::AppState>();
        let s = st.settings.read().unwrap().clone();
        crate::ui::refresh_tray(app, &s, st.hk.paused.load(Ordering::Relaxed));
    }
}

/// 启动后延迟检查，之后每 12 小时检查一次；失败静默
pub fn schedule<R: Runtime>(app: &AppHandle<R>) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(10)).await;
        loop {
            check(&app, false);
            tokio::time::sleep(Duration::from_secs(12 * 3600)).await;
        }
    });
}

pub fn check<R: Runtime>(app: &AppHandle<R>, manual: bool) {
    if matches!(state().as_str(), "checking" | "downloading") {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if manual {
            set(&app, json!({ "state": "checking" }));
        }
        let r = async { anyhow::Ok(app.updater()?.check().await?.map(|u| u.version)) }.await;
        match r {
            Ok(Some(v)) => set(&app, json!({ "state": "available", "version": v })),
            Ok(None) => set(&app, json!({ "state": "latest" })),
            Err(e) if manual => set(&app, json!({ "state": "error", "error": e.to_string() })),
            Err(_) => {}
        }
    });
}

/// 下载并安装最新版，完成后重启
pub fn install<R: Runtime>(app: &AppHandle<R>) {
    if matches!(state().as_str(), "checking" | "downloading") {
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        set(&app, json!({ "state": "downloading", "progress": 0 }));
        let r = async {
            let u = app.updater()?.check().await?.ok_or_else(|| anyhow::anyhow!("已是最新版本"))?;
            let (mut got, mut last) = (0u64, 0u64);
            let a = app.clone();
            u.download_and_install(
                move |n, total| {
                    got += n as u64;
                    let p = total.filter(|t| *t > 0).map_or(0, |t| got * 100 / t);
                    if p != last {
                        last = p;
                        set(&a, json!({ "state": "downloading", "progress": p }));
                    }
                },
                || {},
            )
            .await?;
            anyhow::Ok(())
        }
        .await;
        match r {
            Ok(()) => app.restart(),
            Err(e) => set(&app, json!({ "state": "error", "error": e.to_string() })),
        }
    });
}
