//! SenseVoice 本地识别：录音期间攒帧，松手后整段交给常驻的 Python 服务推理（GPU/CPU 由服务决定）
use anyhow::{anyhow, bail, Result};
use base64::Engine as _;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{mpsc, oneshot};
use voicekey_core::{Audio, Engine, Partial};

/// 推理服务脚本，随二进制放在同目录
pub const SCRIPT: &str = "sensevoice_server.py";

/// 模型必需文件：%APPDATA%\VoiceKey\sensevoice
pub const MODEL_ENTRIES: &[&str] = &[
    "model.pt",
    "config.yaml",
    "configuration.json",
    "tokens.json",
    "am.mvn",
    "chn_jpn_yue_eng_ko_spectok.bpe.model",
];

pub fn model_dir() -> PathBuf {
    voicekey_core::util::data_dir().join("sensevoice")
}

pub fn installed() -> bool {
    let d = model_dir();
    MODEL_ENTRIES.iter().all(|n| d.join(n).is_file())
}

pub fn script() -> Option<PathBuf> {
    let p = std::env::current_exe().ok()?.parent()?.join(SCRIPT);
    p.is_file().then_some(p)
}

struct Server {
    _child: Child,
    tx: mpsc::UnboundedSender<(String, oneshot::Sender<Result<String>>)>,
}

/// 进程内单例：首次用到时启动；服务退出后自动重启
static SERVER: Mutex<Option<Arc<Server>>> = Mutex::new(None);

async fn write_loop(mut stdin: ChildStdin, mut rx: mpsc::UnboundedReceiver<String>) {
    while let Some(line) = rx.recv().await {
        if stdin.write_all(line.as_bytes()).await.is_err() || stdin.flush().await.is_err() {
            return;
        }
    }
}

async fn read_loop(mut r: BufReader<ChildStdout>, otx: mpsc::UnboundedSender<(String, Result<String>)>) {
    loop {
        let mut l = String::new();
        match r.read_line(&mut l).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                let Ok(v) = serde_json::from_str::<Value>(l.trim()) else { continue };
                let id = v["id"].as_str().unwrap_or_default().to_string();
                let out = match v["error"].as_str() {
                    Some(e) => Err(anyhow!("{e}")),
                    None => Ok(v["text"].as_str().unwrap_or_default().trim().to_string()),
                };
                if otx.send((id, out)).is_err() {
                    break;
                }
            }
        }
    }
}

async fn spawn(script: &Path, model: &Path) -> Result<Arc<Server>> {
    let python = std::env::var("SENSEVOICE_PYTHON").unwrap_or_else(|_| "python".into());
    let mut cmd = Command::new(python);
    cmd.arg("-u")
        .arg(script)
        .env("SENSEVOICE_MODEL", model)
        .env("PYTHONIOENCODING", "utf-8")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    #[cfg(windows)]
    {
        // 不弹控制台窗口
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }    let mut child = cmd
        .spawn()
        .map_err(|e| anyhow!("启动 SenseVoice 服务失败（需要 Python + funasr）：{e}"))?;
    let mut stdout = BufReader::new(child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?);
    let stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;

    // 首行必须是 ready；模型加载慢，最多等 3 分钟
    let mut line = String::new();
    match tokio::time::timeout(Duration::from_secs(180), stdout.read_line(&mut line)).await {
        Ok(Ok(n)) if n > 0 => {}
        _ => bail!("SenseVoice 服务启动超时"),
    }
    let v: Value = serde_json::from_str(line.trim()).map_err(|e| anyhow!("服务输出异常：{e}"))?;
    if v["ready"] != Value::Bool(true) {
        bail!("{}", v["error"].as_str().unwrap_or("SenseVoice 服务启动失败"));
    }

    let (tx, mut rx) = mpsc::unbounded_channel::<(String, oneshot::Sender<Result<String>>)>();
    let (wtx, wrx) = mpsc::unbounded_channel::<String>();
    let (otx, mut orx) = mpsc::unbounded_channel::<(String, Result<String>)>();
    tokio::spawn(write_loop(stdin, wrx));
    tokio::spawn(read_loop(stdout, otx));

    let wt = wtx.clone();
    tokio::spawn(async move {
        let mut pending: HashMap<String, oneshot::Sender<Result<String>>> = HashMap::new();
        let mut n: u64 = 0;
        loop {
            tokio::select! {
                Some((pcm, done)) = rx.recv() => {
                    n += 1;
                    let id = n.to_string();
                    let line = serde_json::json!({ "id": id, "pcm": pcm }).to_string() + "\n";
                    if wt.send(line).is_err() {
                        let _ = done.send(Err(anyhow!("SenseVoice 服务已退出")));
                    } else {
                        pending.insert(id, done);
                    }
                }
                Some((id, r)) = orx.recv() => {
                    if let Some(done) = pending.remove(&id) {
                        let _ = done.send(r);
                    }
                }
                else => break,
            }
        }
        for (_, done) in pending.drain() {
            let _ = done.send(Err(anyhow!("SenseVoice 服务已退出")));
        }
    });

    Ok(Arc::new(Server { _child: child, tx }))
}

async fn server() -> Result<Arc<Server>> {
    if let Some(s) = SERVER.lock().unwrap().clone() {
        return Ok(s);
    }
    let script = script().ok_or_else(|| anyhow!("缺少 {SCRIPT}，请放在程序同目录"))?;
    let model = model_dir();
    if !installed() {
        bail!("本地模型未就绪");
    }
    let s = spawn(&script, &model).await?;
    *SERVER.lock().unwrap() = Some(s.clone());
    Ok(s)
}

pub struct LocalEngine;

/// 录音中每隔这么久把「到此为止」的音频重识别一次，作为中间结果
const PARTIAL_EVERY: Duration = Duration::from_millis(700);
/// 首包前至少要有这么多音频，太短识别不出东西
const PARTIAL_MIN: Duration = Duration::from_millis(400);

async fn infer(pcm: &[i16]) -> Result<String> {
    let bytes: Vec<u8> = pcm.iter().flat_map(|s| s.to_le_bytes()).collect();
    let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
    let srv = server().await?;
    let (done, rx) = oneshot::channel();
    srv.tx.send((b64, done)).map_err(|_| anyhow!("SenseVoice 服务已退出"))?;
    rx.await.map_err(|_| anyhow!("SenseVoice 服务已退出"))?
}

#[async_trait::async_trait]
impl Engine for LocalEngine {
    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        // SenseVoice 没有增量解码：每次都用「到目前为止的全部音频」重新识别。
        // GPU 上一次完整前向只要几十毫秒且与音频长度几乎无关，因此录音期间定时重识别即可获得近实时效果；
        // 实测纯中文音频的多次识别结果是严格前缀关系，中间结果可以直接覆盖上屏。
        let shared: Arc<Mutex<Vec<i16>>> = Arc::new(Mutex::new(Vec::with_capacity(16000 * 10)));

        // 中途识别放到独立任务：推理不能阻塞收帧，否则中间结果会被推迟到录音结束
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        // 已推送过的中间结果，用于过滤不稳定（会回退）的识别输出
        let shown = Arc::new(Mutex::new(String::new()));
        let watcher = {
            let shared = shared.clone();
            let stop = stop.clone();
            let shown = shown.clone();
            let partial = Arc::new(partial);
            tokio::spawn(async move {
                let mut ticker = tokio::time::interval(PARTIAL_EVERY);
                ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
                ticker.tick().await;
                loop {
                    ticker.tick().await;
                    if stop.load(std::sync::atomic::Ordering::Relaxed) {
                        break;
                    }
                    let snapshot = shared.lock().unwrap().clone();
                    if (snapshot.len() as f64 / 16000.0) < PARTIAL_MIN.as_secs_f64() {
                        continue;
                    }
                    let Ok(t) = infer(&snapshot).await else { continue };
                    if t.is_empty() || stop.load(std::sync::atomic::Ordering::Relaxed) {
                        continue;
                    }
                    // 只前推不回退：模型几次识别的结果在尾部会波动（中英混句尤其明显），
                    // 覆盖会导致 Typer 退格重打、屏幕闪烁。这里允许尾部继续增长，只在
                    // 「新结果比已显示的短」且「已显示内容不是新结果的前缀」时丢弃这次输出。
                    let prev = shown.lock().unwrap().clone();
                    let grew = t.chars().count() >= prev.chars().count() || prev.starts_with(&t);
                    if !grew {
                        continue;
                    }
                    *shown.lock().unwrap() = t.clone();
                    partial(&t);
                }
            })
        };

        while let Some(frame) = audio.recv().await {
            shared.lock().unwrap().extend_from_slice(&frame);
        }
        // 先停下中途识别，再做定稿，避免定稿之后又来一个更短的中间结果
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        let _ = watcher.await;

        let pcm = std::mem::take(&mut *shared.lock().unwrap());
        if pcm.is_empty() {
            return Ok(String::new());
        }
        // 松手后的定稿：同样是对全量音频的一次识别，覆盖掉最后一段中间结果
        infer(&pcm).await
    }

    async fn prewarm(&self) {
        // 提前拉起进程、加载模型，省掉第一次说话的十几秒
        let _ = server().await;
    }
}
