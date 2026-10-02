//! 微信离线：从微信输入法资源 CDN 下载官方语音包并解包，推理由 voicekey-wtlocal 完成（全平台）
use anyhow::{bail, Result};
use futures_util::StreamExt;
use md5::{Digest, Md5};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Runtime};
use tokio::io::AsyncWriteExt;
use voicekey_core::{util::data_dir, Engine};
use voicekey_wtlocal::{pack, LocalEngine};

pub fn dir() -> PathBuf {
    data_dir().join("wtoffline")
}

/// 解包成功后才整体改名为正式目录
pub fn installed() -> bool {
    dir().is_dir()
}

pub fn engine() -> Arc<dyn Engine> {
    Arc::new(LocalEngine { dir: dir() })
}

static STATUS: Mutex<Option<Value>> = Mutex::new(None);

pub fn status() -> Value {
    if let Some(v) = STATUS.lock().unwrap().clone() {
        return v;
    }
    json!({ "state": if installed() { "ready" } else { "missing" } })
}

fn set_status<R: Runtime>(app: &AppHandle<R>, v: Value) {
    *STATUS.lock().unwrap() = Some(v.clone());
    let _ = app.emit("model", json!({ "ch": "wetypeoffline", "status": v }));
}

pub fn download<R: Runtime>(app: &AppHandle<R>) {
    if installed() || status()["state"] == "downloading" {
        return;
    }
    let app = app.clone();
    set_status(&app, json!({ "state": "downloading", "progress": 0.0 }));
    tauri::async_runtime::spawn(async move {
        let r = install(&app).await;
        set_status(&app, match r {
            Ok(()) => json!({ "state": "ready" }),
            Err(e) => json!({ "state": "failed", "error": format!("{e:#}") }),
        });
    });
}

async fn install<R: Runtime>(app: &AppHandle<R>) -> Result<()> {
    let apk = data_dir().join("wtoffline.apk");
    let part = apk.with_extension("part");
    let resp = reqwest::get(pack::URL).await?;
    if !resp.status().is_success() {
        bail!("下载失败 HTTP {}", resp.status());
    }
    let mut file = tokio::fs::File::create(&part).await?;
    let mut md5 = Md5::new();
    let mut stream = resp.bytes_stream();
    let (mut n, mut last) = (0u64, Instant::now());
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        file.write_all(&chunk).await?;
        md5.update(&chunk);
        n += chunk.len() as u64;
        if last.elapsed() > Duration::from_millis(200) {
            last = Instant::now();
            set_status(app, json!({ "state": "downloading", "progress": n as f64 / pack::SIZE as f64 * 0.98 }));
        }
    }
    file.flush().await?;
    drop(file);
    if hex::encode(md5.finalize()) != pack::MD5 {
        let _ = std::fs::remove_file(&part);
        bail!("语音包校验失败");
    }
    std::fs::rename(&part, &apk)?;
    let r = tokio::task::spawn_blocking(move || {
        let r = pack::unpack(&apk, &dir());
        let _ = std::fs::remove_file(&apk);
        r
    })
    .await?;
    r
}
