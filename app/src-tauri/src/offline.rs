//! 离线识别：仅 macOS arm64（在 worker 子进程内加载安卓 ELF 引擎），其他平台禁用
use anyhow::{anyhow, bail, Result};
use base64::Engine as _;
use futures_util::StreamExt;
use md5::Md5;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Runtime};
use tokio::io::AsyncWriteExt;
use voicekey_core::{util::data_dir, Audio, Engine, Partial};

pub const SUPPORTED: bool = cfg!(all(target_os = "macos", target_arch = "aarch64"));

struct Asset {
    name: &'static str,
    url: &'static str,
    size: u64,
    sha256: Option<&'static str>,
    md5: Option<&'static str>,
}

const LIBS: &str = "https://github.com/J3n5en/voicekey/releases/download/offline-libs/";
const ASSETS: [Asset; 4] = [
    Asset { name: "libc++_shared.so", url: "libc%2B%2B_shared.so", size: 911_696, sha256: Some("e8373ee43274541efd2d34fe0588d55bf953612e1417ad47cfd2c4bd1aa383d0"), md5: None },
    Asset { name: "libiesapplogger.so", url: "libiesapplogger.so", size: 67_616, sha256: Some("08fc4396d0e80aafd83d646ed875289c5987f68a6b3f0827ba1605d2f12130f2"), md5: None },
    Asset { name: "libaudioeffect.so", url: "libaudioeffect.so", size: 7_462_456, sha256: Some("5303cab48de6ef5db6ace4d54779b0e64f9e2eb6a2600dd41638f6d9b67d110f"), md5: None },
    Asset { name: "model.flute", url: "https://lf3-effectcdn-tos.byteeffecttos.com/obj/ies.fe.effect/b78e55b937a6f7da432097d2d9dc7214?module=model", size: 185_377_526, sha256: None, md5: Some("b78e55b937a6f7da432097d2d9dc7214") },
];

impl Asset {
    fn url(&self) -> String {
        if self.url.starts_with("https://") { self.url.to_string() } else { format!("{LIBS}{}", self.url) }
    }
}

pub fn dir() -> PathBuf {
    let d = data_dir().join("offline");
    let _ = std::fs::create_dir_all(&d);
    d
}

fn present(a: &Asset) -> bool {
    std::fs::metadata(dir().join(a.name)).is_ok_and(|m| m.len() == a.size)
}

pub fn installed() -> bool {
    SUPPORTED && ASSETS.iter().all(present)
}

// MARK: - 下载

static STATUS: Mutex<Option<Value>> = Mutex::new(None);

pub fn status() -> Value {
    if let Some(v) = STATUS.lock().unwrap().clone() {
        return v;
    }
    json!({ "state": if installed() { "ready" } else { "missing" } })
}

fn set_status<R: Runtime>(app: &AppHandle<R>, v: Value) {
    *STATUS.lock().unwrap() = Some(v.clone());
    let _ = app.emit("model", json!({ "ch": "offline", "status": v }));
}

/// 后台下载引擎库与模型，进度经 "model" 事件推送
pub fn download<R: Runtime>(app: &AppHandle<R>) {
    if !SUPPORTED || installed() || status()["state"] == "downloading" {
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
    let total: u64 = ASSETS.iter().map(|a| a.size).sum();
    let mut done: u64 = ASSETS.iter().filter(|a| present(a)).map(|a| a.size).sum();
    let client = reqwest::Client::new();
    for a in ASSETS.iter().filter(|a| !present(a)) {
        let resp = client.get(a.url()).send().await?;
        if !resp.status().is_success() {
            bail!("下载失败 HTTP {}", resp.status());
        }
        let tmp = dir().join(format!("{}.part", a.name));
        let mut file = tokio::fs::File::create(&tmp).await?;
        let (mut sha, mut md5) = (Sha256::new(), Md5::new());
        let mut stream = resp.bytes_stream();
        let (mut n, mut last) = (0u64, Instant::now());
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?;
            file.write_all(&chunk).await?;
            if a.sha256.is_some() {
                sha.update(&chunk)
            } else {
                md5.update(&chunk)
            }
            n += chunk.len() as u64;
            if last.elapsed() > Duration::from_millis(200) {
                last = Instant::now();
                set_status(app, json!({ "state": "downloading", "progress": (done + n) as f64 / total as f64 }));
            }
        }
        file.flush().await?;
        drop(file);
        let ok = match (a.sha256, a.md5) {
            (Some(h), _) => hex::encode(sha.finalize()) == h,
            (_, Some(h)) => hex::encode(md5.finalize()) == h,
            _ => true,
        };
        if !ok {
            let _ = std::fs::remove_file(&tmp);
            bail!("{} 校验失败", a.name);
        }
        std::fs::rename(&tmp, dir().join(a.name))?;
        done += a.size;
    }
    Ok(())
}

// MARK: - worker 子进程

/// 离线识别子进程（VoiceKey --offline-worker <model>，stdin/stdout JSON-lines），崩溃不影响主进程，空闲 5 分钟退出释放内存
struct Worker {
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    stdout: Option<BufReader<ChildStdout>>,
    gen: u64,
}

static WORKER: Mutex<Worker> = Mutex::new(Worker { child: None, stdin: None, stdout: None, gen: 0 });

impl Worker {
    fn launch(&mut self) -> Result<()> {
        if !installed() {
            bail!("离线模型未下载");
        }
        let mut child = Command::new(std::env::current_exe()?)
            .arg("--offline-worker")
            .arg(dir().join("model.flute"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        self.stdin = child.stdin.take();
        self.stdout = child.stdout.take().map(BufReader::new);
        self.child = Some(child);
        Ok(())
    }

    fn running(&mut self) -> bool {
        self.child.as_mut().is_some_and(|c| c.try_wait().ok().flatten().is_none())
    }

    fn stop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        self.stdin = None;
        self.stdout = None;
    }

    fn call(&mut self, op: &str, b64: Option<&str>) -> Result<String> {
        if !self.running() {
            self.launch()?;
        }
        let mut req = json!({ "op": op });
        if let Some(b) = b64 {
            req["b64"] = json!(b);
        }
        let mut io = || -> std::io::Result<String> {
            let w = self.stdin.as_mut().ok_or(std::io::ErrorKind::BrokenPipe)?;
            writeln!(w, "{req}")?;
            w.flush()?;
            let mut line = String::new();
            self.stdout.as_mut().ok_or(std::io::ErrorKind::BrokenPipe)?.read_line(&mut line)?;
            Ok(line)
        };
        let reply: Option<Value> = io().ok().and_then(|l| serde_json::from_str(&l).ok());
        let Some(v) = reply else {
            self.stop();
            bail!("离线引擎异常退出");
        };
        if v["ok"] != true {
            bail!("离线引擎错误：{}", v["error"].as_str().unwrap_or("未知"));
        }
        Ok(v["text"].as_str().unwrap_or_default().to_string())
    }
}

fn schedule_idle(gen: u64) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(300));
        let mut w = WORKER.lock().unwrap();
        if w.gen == gen {
            w.stop();
        }
    });
}

async fn call(op: &'static str, b64: Option<String>) -> Result<String> {
    tokio::task::spawn_blocking(move || {
        let mut w = WORKER.lock().unwrap();
        w.gen += 1;
        let r = w.call(op, b64.as_deref());
        schedule_idle(w.gen);
        r
    })
    .await
    .map_err(|e| anyhow!("{e}"))?
}

pub struct OfflineEngine;

#[async_trait::async_trait]
impl Engine for OfflineEngine {
    async fn prewarm(&self) {
        if !installed() {
            return;
        }
        let _ = tokio::task::spawn_blocking(|| {
            let mut w = WORKER.lock().unwrap();
            w.gen += 1;
            if !w.running() {
                let _ = w.launch();
            }
            schedule_idle(w.gen);
        })
        .await;
    }

    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        if !installed() {
            bail!("离线模型未就绪，请在设置中查看下载进度");
        }
        call("begin", None).await?;
        let r: Result<String> = async {
            let (mut pcm, mut last) = (Vec::<u8>::new(), String::new());
            loop {
                let frame = audio.recv().await;
                if let Some(f) = &frame {
                    pcm.extend(f.iter().flat_map(|s| s.to_le_bytes()));
                }
                // 100ms 一块，引擎按此粒度处理
                if pcm.len() >= 3200 || (frame.is_none() && !pcm.is_empty()) {
                    let b64 = base64::engine::general_purpose::STANDARD.encode(&pcm);
                    pcm.clear();
                    let text = call("chunk", Some(b64)).await?;
                    if !text.is_empty() && text != last {
                        partial(&text);
                        last = text;
                    }
                }
                if frame.is_none() {
                    break;
                }
            }
            call("end", None).await
        }
        .await;
        if r.is_err() {
            let _ = call("cancel", None).await;
        }
        r
    }
}

pub fn engine() -> Option<Arc<dyn Engine>> {
    SUPPORTED.then(|| Arc::new(OfflineEngine) as Arc<dyn Engine>)
}

/// 子进程入口：返回 Some(退出码) 表示本进程是 worker
pub fn worker_main() -> Option<i32> {
    let args: Vec<String> = std::env::args().collect();
    (args.len() >= 3 && args[1] == "--offline-worker").then(|| voicekey_hanbao::run_worker(&args[2], &dir().to_string_lossy()))
}
