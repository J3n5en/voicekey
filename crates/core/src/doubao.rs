use crate::pb::{self, PBuf};
use crate::util::{data_file, join_sentences, now_ms};
use crate::ws::{self, AbortOnDrop};
use crate::{opus, Audio, Engine, Partial};
use anyhow::{anyhow, bail, Result};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

const WS_URL: &str = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws";
const UA: &str = "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)";
const OK: i64 = 20_000_000;
const FIRST: u64 = 1;
const MIDDLE: u64 = 3;
const LAST: u64 = 9;

/// 豆包输入法流式识别：asr.AsrRequest protobuf over WSS，Opus 20ms 帧
#[derive(Default)]
pub struct DoubaoEngine;

fn request(token: &str, method: &str, payload: &str, audio: &[u8], rid: &str, frame: u64) -> Message {
    let mut pb = PBuf::new();
    if !token.is_empty() {
        pb = pb.s(2, token);
    }
    pb = pb.s(3, "ASR").s(5, method);
    if !payload.is_empty() {
        pb = pb.s(6, payload);
    }
    if !audio.is_empty() {
        pb = pb.b(7, audio);
    }
    pb = pb.s(8, rid);
    if frame != 0 {
        pb = pb.v(9, frame);
    }
    Message::Binary(pb.0.into())
}

struct Response {
    event: String,
    status: i64,
    message: String,
    result: String,
}

impl Response {
    fn parse(data: &[u8]) -> Result<Self> {
        let f = pb::parse(data)?;
        Ok(Self {
            event: f.string(4).unwrap_or_default(),
            status: f.varint(5).unwrap_or(0) as i32 as i64,
            message: f.string(6).unwrap_or_default(),
            result: f.string(7).unwrap_or_default(),
        })
    }
    fn failed(&self) -> anyhow::Error {
        anyhow!("豆包 {} {}: {}", self.event, self.status, self.message)
    }
}

/// 上游按句定稿（index 递增，同一句可能再次定稿按 index 覆盖）；展示 = 已定稿句 + 当前句
#[derive(Default)]
struct Transcript {
    sentences: BTreeMap<i64, String>,
    current: String,
    next_index: i64,
}

impl Transcript {
    fn result(&self) -> String {
        if self.sentences.is_empty() {
            self.current.clone()
        } else {
            join_sentences(&self.sentences.values().collect::<Vec<_>>())
        }
    }

    fn update(&mut self, json: &str) -> Option<String> {
        let v: Value = serde_json::from_str(json).ok()?;
        for r in v.get("results")?.as_array()? {
            let Some(t) = r["text"].as_str().filter(|t| !t.is_empty()) else { continue };
            let fin = r["extra"]["nonstream_result"].as_bool().unwrap_or(false)
                || (r["is_interim"].as_bool() == Some(false) && r["is_vad_finished"].as_bool() == Some(true));
            if fin {
                let idx = r["index"].as_i64().unwrap_or(self.next_index);
                self.sentences.insert(idx, t.to_string());
                self.next_index = self.next_index.max(idx + 1);
                self.current.clear();
            } else {
                self.current = t.to_string();
            }
        }
        let mut parts: Vec<&String> = self.sentences.values().collect();
        parts.push(&self.current);
        Some(join_sentences(&parts))
    }
}

#[async_trait::async_trait]
impl Engine for DoubaoEngine {
    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        // 录音同时留底：服务端拒绝当前设备（SessionFailed 且无结果）时换新设备重放一次
        let (ftx, frx) = tokio::sync::mpsc::unbounded_channel();
        let kept = Arc::new(Mutex::new(Vec::new()));
        let k = kept.clone();
        let _tee = AbortOnDrop(tokio::spawn(async move {
            while let Some(f) = audio.recv().await {
                k.lock().unwrap().push(f.clone());
                let _ = ftx.send(f);
            }
        }));
        let partial: Arc<Partial> = Arc::new(partial);
        match session(frx, partial.clone()).await {
            Err(Fail::Rejected(e)) => {
                DoubaoDevice::reset();
                let (rtx, rrx) = tokio::sync::mpsc::unbounded_channel();
                let frames = std::mem::take(&mut *kept.lock().unwrap());
                // 4 倍速回放，一次性灌入会被服务端拒绝
                let _replay = AbortOnDrop(tokio::spawn(async move {
                    for f in frames {
                        if rtx.send(f).is_err() {
                            break;
                        }
                        tokio::time::sleep(Duration::from_millis(5)).await;
                    }
                }));
                session(rrx, partial).await.map_err(|r| {
                    DoubaoDevice::reset();
                    anyhow!("{e}；换设备重试：{}", r.into_inner())
                })
            }
            r => r.map_err(Fail::into_inner),
        }
    }
}

/// Rejected：服务端判会话失败且无任何结果，可换设备重试
enum Fail {
    Other(anyhow::Error),
    Rejected(anyhow::Error),
}
impl Fail {
    fn into_inner(self) -> anyhow::Error {
        match self {
            Fail::Other(e) | Fail::Rejected(e) => e,
        }
    }
}
impl<E: Into<anyhow::Error>> From<E> for Fail {
    fn from(e: E) -> Self {
        Fail::Other(e.into())
    }
}

async fn session(mut audio: Audio, partial: Arc<Partial>) -> std::result::Result<String, Fail> {
    {
        let device = DoubaoDevice::load().await?;
        let rid = uuid::Uuid::new_v4().to_string();
        let url = format!("{WS_URL}?aid=401734&device_id={}", device.did);
        let ws = ws::connect(&url, &[("User-Agent", UA), ("proto-version", "v2"), ("x-custom-keepalive", "true")]).await?;
        let (mut tx, mut rx) = ws.split();

        let session = json!({
            "audio_info": {"channel": 1, "format": "speech_opus", "sample_rate": 16000},
            "enable_punctuation": true,
            "enable_speech_rejection": true,
            "extra": {"app_name": "oime", "cell_compress_rate": 8, "did": device.did,
                      "enable_asr_threepass": true, "enable_asr_twopass": true, "input_mode": "stream"},
        })
        .to_string();
        let handshake = async {
            tx.send(request(&device.token, "StartTask", "", &[], &rid, 0)).await?;
            expect(&mut rx, "TaskStarted").await?;
            tx.send(request(&device.token, "StartSession", &session, &[], &rid, 0)).await?;
            expect(&mut rx, "SessionStarted").await
        };
        if let Err(e) = handshake.await {
            DoubaoDevice::reset();
            return Err(e.into());
        }

        let transcript = Arc::new(Mutex::new(Transcript::default()));
        let t = transcript.clone();
        let receiver = AbortOnDrop(tokio::spawn(async move {
            loop {
                // 静音期间上游不回包，超时只兜底；结束阶段由外层限时
                let r = Response::parse(&ws::recv(&mut rx, Duration::from_secs(600)).await?)?;
                if !r.result.is_empty() {
                    let text = t.lock().unwrap().update(&r.result);
                    if let Some(text) = text {
                        partial(&text);
                    }
                }
                if r.event.ends_with("Failed") {
                    return Err(r.failed());
                }
                if r.event == "SessionFinished" {
                    return Ok(());
                }
            }
        }));

        let mut enc = opus::Opus::new(opus::VOIP, 16000, 5)?;
        let ts0 = now_ms();
        let meta = |i: u64| format!(r#"{{"extra":{{}},"timestamp_ms":{}}}"#, ts0 + i * 20);
        let mut index = 0u64;
        while let Some(frame) = audio.recv().await {
            let pkt = enc.encode(&frame)?;
            let kind = if index == 0 { FIRST } else { MIDDLE };
            tx.send(request("", "TaskRequest", &meta(index), &pkt, &rid, kind)).await?;
            index += 1;
        }
        tx.send(request("", "TaskRequest", &meta(index), &[], &rid, LAST)).await?;
        tx.send(request(&device.token, "FinishSession", "", &[], &rid, 0)).await?;

        let limit = Duration::from_secs_f64(10.0 + index as f64 / 200.0);
        let mut receiver = receiver;
        let outcome = match tokio::time::timeout(limit, &mut receiver).await {
            Ok(r) => r.map_err(|e| anyhow!("{e}")).and_then(|r| r),
            Err(_) => Err(anyhow!("豆包定稿超时")),
        };
        let _ = tx.close().await;
        let text = transcript.lock().unwrap().result();
        match outcome {
            // 如设备被服务端拉黑后的 service discovery failure
            Err(e) if text.is_empty() && e.to_string().contains("Failed") => Err(Fail::Rejected(e)),
            Err(e) if text.is_empty() => Err(e.into()),
            _ => Ok(text),
        }
    }
}

async fn expect<S>(rx: &mut S, event: &str) -> Result<()>
where
    S: futures_util::Stream<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    loop {
        let r = Response::parse(&ws::recv(rx, Duration::from_secs(10)).await?)?;
        if r.event.ends_with("Failed") || (r.event == event && r.status != OK) {
            return Err(r.failed());
        }
        if r.event == event {
            return Ok(());
        }
    }
}

/// 设备注册 + settings 拉取 asr app_key，本地缓存复用
#[derive(Serialize, Deserialize, Clone)]
struct DoubaoDevice {
    did: String,
    token: String,
}

const APP: &[(&str, &str)] = &[
    ("aid", "401734"), ("app_name", "oime"), ("channel", "official"),
    ("version_code", "100102018"), ("version_name", "1.1.2"),
    ("manifest_version_code", "100102018"), ("update_version_code", "100102018"),
    ("package", "com.bytedance.android.doubaoime"),
];
const DEV: &[(&str, &str)] = &[
    ("device_platform", "android"), ("os", "android"), ("os_api", "34"), ("os_version", "16"),
    ("device_type", "Pixel 7 Pro"), ("device_brand", "google"), ("device_model", "Pixel 7 Pro"),
    ("resolution", "1080*2400"), ("dpi", "420"), ("language", "zh"), ("timezone", "8"),
    ("access", "wifi"), ("rom", "UP1A.231005.007"), ("rom_version", "UP1A.231005.007"),
];

impl DoubaoDevice {
    fn file() -> std::path::PathBuf {
        data_file("doubao.json")
    }

    async fn load() -> Result<Self> {
        if let Some(d) = std::fs::read(Self::file()).ok().and_then(|b| serde_json::from_slice(&b).ok()) {
            return Ok(d);
        }
        let d = Self::register().await?;
        let _ = std::fs::write(Self::file(), serde_json::to_vec(&d)?);
        Ok(d)
    }

    fn reset() {
        let _ = std::fs::remove_file(Self::file());
    }

    async fn post(url: &str, query: &[(&str, String)], body: Vec<u8>, ctype: &str, extra: &[(&str, &str)]) -> Result<Value> {
        let mut req = reqwest::Client::new()
            .post(url)
            .query(query)
            .timeout(Duration::from_secs(10))
            .header("User-Agent", UA)
            .header("Content-Type", ctype)
            .body(body);
        for (k, v) in extra {
            req = req.header(*k, *v);
        }
        let resp = req.send().await?;
        if resp.status() != 200 {
            bail!("豆包设备注册 HTTP 失败");
        }
        Ok(resp.json().await.unwrap_or(Value::Null))
    }

    async fn register() -> Result<Self> {
        let cdid = uuid::Uuid::new_v4().to_string();
        let now = now_ms().to_string();
        let mut header = serde_json::Map::new();
        for (k, v) in APP.iter().chain(DEV) {
            header.insert(k.to_string(), json!(v));
        }
        let extra = json!({
            "device_id": 0, "install_id": 0, "cdid": cdid,
            "openudid": format!("{:08x}", rand::random::<u32>()),
            "clientudid": uuid::Uuid::new_v4().to_string(),
            "region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800,
            "sim_region": "cn", "carrier_region": "cn", "cpu_abi": "arm64-v8a", "build_serial": "unknown",
            "not_request_sender": 0, "sig_hash": "", "google_aid": "", "mc": "", "serial_number": "",
        });
        header.extend(extra.as_object().unwrap().clone());
        let body = json!({"magic_tag": "ss_app_log", "header": header, "_gen_time": now.parse::<u64>()?});

        let mut q: Vec<(&str, String)> = APP.iter().chain(DEV).map(|(k, v)| (*k, v.to_string())).collect();
        q.extend([("ssmix", "a".into()), ("_rticket", now.clone()), ("cdid", cdid.clone()), ("ac", "wifi".into())]);
        let reg = Self::post("https://log.snssdk.com/service/2/device_register/", &q, serde_json::to_vec(&body)?, "application/json", &[]).await?;
        let did = reg["device_id_str"]
            .as_str()
            .map(String::from)
            .or_else(|| reg["device_id"].as_u64().map(|n| n.to_string()))
            .unwrap_or_default();
        if did.is_empty() || did == "0" {
            bail!("豆包设备注册被拒绝");
        }

        let mut q: Vec<(&str, String)> = APP.iter().map(|(k, v)| (*k, v.to_string())).collect();
        q.extend([
            ("device_platform", "android".into()), ("os", "android".into()), ("ssmix", "a".into()),
            ("_rticket", now), ("cdid", cdid), ("device_id", did.clone()),
        ]);
        let settings = Self::post(
            "https://is.snssdk.com/service/settings/v3/", &q, b"body=null".to_vec(),
            "application/x-www-form-urlencoded", &[("x-ss-stub", "46c03b52742b3f2615a3abdf1636b754")],
        )
        .await?;
        let token = settings["data"]["settings"]["asr_config"]["app_key"].as_str().unwrap_or_default().to_string();
        if token.is_empty() {
            bail!("豆包 settings 未返回 app_key");
        }
        Ok(Self { did, token })
    }
}
