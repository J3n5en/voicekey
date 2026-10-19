//! SenseVoice 本地识别：模型与推理脚本都在本机，音频不出本机
use anyhow::{bail, Result};
use futures_util::StreamExt;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Runtime};
use tokio::io::AsyncWriteExt;
use voicekey_core::Engine;

pub use voicekey_sensevoice::installed;
use voicekey_sensevoice::{model_dir, SCRIPT};

/// 模型文件来源（HuggingFace 官方仓库，公开可下）
const BASE: &str = "https://huggingface.co/FunAudioLLM/SenseVoiceSmall/resolve/main/";

struct Asset {
    name: &'static str,
    size: u64,
    sha256: &'static str,
}

/// 必需文件与校验值；顺序按体积从小到大，先装小文件便于早失败
const ASSETS: [Asset; 6] = [
    Asset {
        name: "configuration.json",
        size: 396,
        sha256: "02810a7f8e9e8aee10370a265f7e799728ce25b4c00cdbf4602b303ee395a38e",
    },
    Asset {
        name: "config.yaml",
        size: 1855,
        sha256: "f71e239ba36705564b5bf2d2ffd07eece07b8e3f2bbf6d2c99d8df856339ac19",
    },
    Asset {
        name: "am.mvn",
        size: 11203,
        sha256: "29b3c740a2c0cfc6b308126d31d7f265fa2be74f3bb095cd2f143ea970896ae5",
    },
    Asset {
        name: "tokens.json",
        size: 352064,
        sha256: "a2594fc1474e78973149cba8cd1f603ebed8c39c7decb470631f66e70ce58e97",
    },
    Asset {
        name: "chn_jpn_yue_eng_ko_spectok.bpe.model",
        size: 377341,
        sha256: "aa87f86064c3730d799ddf7af3c04659151102cba548bce325cf06ba4da4e6a8",
    },
    Asset {
        name: "model.pt",
        size: 936291369,
        sha256: "833ca2dcfdf8ec91bd4f31cfac36d6124e0c459074d5e909aec9cabe6204a3ea",
    },
];

static STATUS: Mutex<Option<Value>> = Mutex::new(None);

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

fn present(a: &Asset) -> bool {
    model_dir().join(a.name).is_file()
}

/// 后台下载模型，进度经 "model" 事件推送；已存在的文件跳过，中断后可续
pub fn download<R: Runtime>(app: &AppHandle<R>) {
    if installed() || status()["state"] == "downloading" {
        return;
    }
    // 推理脚本随应用打包，缺了就没法跑，先确认再开始下 1GB
    if !script_present() {
        set_status(&app, json!({ "state": "failed", "error": format!("缺少 {SCRIPT}，请重新安装 VoiceKey") }));
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
    let dir = model_dir();
    tokio::fs::create_dir_all(&dir).await?;
    let total: u64 = ASSETS.iter().map(|a| a.size).sum();
    let mut done: u64 = ASSETS.iter().filter(|a| present(a)).map(|a| a.size).sum();
    let client = reqwest::Client::new();

    for a in ASSETS.iter().filter(|a| !present(a)) {
        let resp = client.get(format!("{BASE}{}", a.name)).send().await?;
        if !resp.status().is_success() {
            bail!("下载 {} 失败：HTTP {}", a.name, resp.status());
        }
        let tmp = dir.join(format!("{}.part", a.name));
        let mut file = tokio::fs::File::create(&tmp).await?;
        let mut sha = Sha256::new();
        let mut stream = resp.bytes_stream();
        let (mut n, mut last) = (0u64, Instant::now());
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            file.write_all(&chunk).await?;
            sha.update(&chunk);
            n += chunk.len() as u64;
            if last.elapsed() > Duration::from_millis(200) {
                last = Instant::now();
                set_status(app, json!({ "state": "downloading", "progress": (done + n) as f64 / total as f64 }));
            }
        }
        file.flush().await?;
        drop(file);
        if hex::encode(sha.finalize()) != a.sha256 {
            let _ = tokio::fs::remove_file(&tmp).await;
            bail!("{} 校验失败，可能下载不完整，请重试", a.name);
        }
        tokio::fs::rename(&tmp, dir.join(a.name)).await?;
        done += a.size;
        set_status(app, json!({ "state": "downloading", "progress": done as f64 / total as f64 }));
    }
    if !installed() {
        bail!("模型文件不完整");
    }
    Ok(())
}

fn script_present() -> bool {
    std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(PathBuf::from).map(|d| d.join(SCRIPT)))
        .is_some_and(|p| p.is_file())
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
