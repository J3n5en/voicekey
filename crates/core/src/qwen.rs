use crate::pb::PBuf;
use crate::util::{data_file, now_ms};
use crate::ws::{self, Ws};
use crate::{Audio, Engine, Partial};
use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
use anyhow::{anyhow, bail, Result};
use base64::Engine as _;
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;

const VE: &str = "1.2.35.46";
const ORIGIN: &str = "https://www.qianwen.com";
const HMAC_KEY: &[u8] = b"2d473b000fdb53e617446f805d4eaaacbb324bd16ee9f6d8237abd0ab79c5e48";
const AES_KEY: &[u8] = b"a0a6237b2b735a54";
const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 TONGYI_DESKTOP/0.1.0 QuarkPC/ime_voice";
const CHUNK: usize = 3840;

fn debug(tag: &str, d: &[u8]) {
    if std::env::var_os("QWEN_DEBUG").is_some() {
        let s = String::from_utf8_lossy(d);
        eprintln!("QWEN_{tag} {}", s.chars().take(800).collect::<String>());
    }
}

/// 千问输入法 ASR：WSG 签名（HMAC-SHA1 + AES-128-CBC），HTTP/1.1 升级后发 protobuf 帧（attach → asr/send PCM → complete）
#[derive(Default)]
pub struct QwenEngine {
    session: Mutex<Option<Session>>,
}

impl QwenEngine {
    async fn take(&self, fresh: bool) -> Result<(Session, bool)> {
        if !fresh {
            if let Some(s) = self.session.lock().await.take().filter(|s| !s.dead) {
                return Ok((s, true));
            }
        }
        match Session::open().await {
            Ok(s) => Ok((s, false)),
            Err(e) => {
                QwenDevice::reset();
                Err(e)
            }
        }
    }
}

#[async_trait::async_trait]
impl Engine for QwenEngine {
    async fn prewarm(&self) {
        let mut slot = self.session.lock().await;
        if slot.as_ref().map_or(true, |s| s.dead) {
            *slot = Session::open().await.ok();
        }
    }

    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        let (mut s, reused) = self.take(false).await?;
        if let Err(e) = s.ensure_attach().await {
            if !reused {
                return Err(e);
            }
            (s, _) = self.take(true).await?;
            s.ensure_attach().await?;
        }

        let mut t = Transcript { partial, asr: String::new(), asr_done: false };
        let ws = s.ws.take().ok_or_else(|| anyhow!("千问连接缺失"))?;
        let (mut sink, mut stream) = ws.split();
        let result: Result<()> = async {
            let mut pcm: Vec<u8> = Vec::new();
            loop {
                tokio::select! {
                    f = audio.recv() => {
                        let Some(f) = f else { break };
                        pcm.extend(f.iter().flat_map(|s| s.to_le_bytes()));
                        while pcm.len() >= CHUNK {
                            let chunk: Vec<u8> = pcm.drain(..CHUNK).collect();
                            sink.send(bin(s.asr_send(&chunk))).await?;
                        }
                    }
                    m = stream.next() => {
                        if let Some(d) = ws::data(m)? { s.handle(&d, &mut t); }
                    }
                }
            }
            if !pcm.is_empty() {
                pcm.resize(CHUNK, 0);
                sink.send(bin(s.asr_send(&pcm))).await?;
            }
            sink.send(bin(s.asr_complete())).await?;
            let deadline = Instant::now() + Duration::from_millis(2000);
            while !t.asr_done && Instant::now() < deadline {
                if let Some(d) = ws::recv_opt(&mut stream, deadline - Instant::now()).await? {
                    s.handle(&d, &mut t);
                }
            }
            Ok(())
        }
        .await;
        result?;
        s.ws = Some(sink.reunite(stream).map_err(|_| anyhow!("千问连接合并失败"))?);
        s.reset();
        *self.session.lock().await = Some(s);
        let text = t.result();
        if text.is_empty() {
            bail!("千问没有识别文本");
        }
        Ok(text)
    }
}

fn bin(d: Vec<u8>) -> Message {
    Message::Binary(d.into())
}

struct Transcript {
    partial: Partial,
    asr: String,
    asr_done: bool,
}

impl Transcript {
    fn result(&self) -> String {
        self.asr.clone()
    }

    fn walk(&mut self, v: &Value) {
        match v {
            Value::Object(d) => {
                if let Some(t) = d.get("content").and_then(|c| c.get("text")).and_then(Value::as_str).filter(|s| !s.is_empty()) {
                    self.asr = t.into();
                    (self.partial)(t);
                }
                if let Some(ms) = d.get("messages").and_then(Value::as_array) {
                    for m in ms {
                        if let Some(s) = m.get("content").and_then(Value::as_str).filter(|s| !s.is_empty()) {
                            let _ = (m, s);
                        }
                    }
                }
                for (k, v) in d {
                    match v.as_str().filter(|s| !s.is_empty()) {
                        Some(s) if k == "translatedText" || k == "translated_text" => {
                            let _ = s;
                        }
                        _ => self.walk(v),
                    }
                }
            }
            Value::Array(a) => a.iter().for_each(|v| self.walk(v)),
            _ => {}
        }
    }
}

struct Session {
    auth: QwenAuth,
    ws: Option<Ws>,
    dead: bool,
    session_id: String,
    round_id: String,
    attached: bool,
}

impl Session {
    async fn open() -> Result<Self> {
        let auth = QwenAuth::make()?;
        let url = format!("wss://voice-input.qianwen.com/ws/v1/voice?{}", auth.query());
        let mut headers = vec![("Cache-Control", "no-cache"), ("User-Agent", UA), ("Origin", ORIGIN)];
        let h = auth.headers();
        headers.extend(h.iter().map(|(k, v)| (*k, v.as_str())));
        let ws = ws::connect(&url, &headers).await.map_err(|e| anyhow!("千问 {e}"))?;
        Ok(Self {
            auth, ws: Some(ws), dead: false, session_id: String::new(), round_id: String::new(),
            attached: false,
        })
    }

    fn ws(&mut self) -> Result<&mut Ws> {
        self.ws.as_mut().ok_or_else(|| anyhow!("千问连接缺失"))
    }

    async fn ensure_attach(&mut self) -> Result<()> {
        if self.attached && !self.session_id.is_empty() {
            return Ok(());
        }
        let r = self.attach().await;
        if r.is_err() {
            self.dead = true;
        }
        r
    }

    async fn attach(&mut self) -> Result<()> {
        let pkt = self.attach_packet()?;
        self.ws()?.send(bin(pkt)).await?;
        let deadline = Instant::now() + Duration::from_secs(8);
        while Instant::now() < deadline && self.session_id.is_empty() {
            let Some(d) = ws::recv_opt(self.ws()?, Duration::from_secs(2)).await? else { continue };
            debug("ATTACH", &d);
            let Ok(v) = serde_json::from_slice::<Value>(&d) else { continue };
            if let Some(sid) = v["data"]["sessionId"].as_str().filter(|s| !s.is_empty()) {
                self.note_session(sid, v["data"]["roundId"].as_str());
            }
        }
        if self.session_id.is_empty() {
            bail!("千问 attach 没有 sessionId");
        }
        Ok(())
    }

    fn handle(&mut self, d: &[u8], t: &mut Transcript) {
        debug("DOWN", d);
        let Ok(v) = serde_json::from_slice::<Value>(d) else { return };
        if let Some(sid) = v["data"]["sessionId"].as_str().filter(|s| !s.is_empty()) {
            if v["route"] == "/voice_assistant/channel/attach" {
                self.note_session(sid, v["data"]["roundId"].as_str());
            }
            if let Some(nr) = v["data"]["newRoundId"].as_str().filter(|s| !s.is_empty()) {
                self.round_id = nr.into();
                t.asr_done = true;
            }
        }
        t.walk(&v);
    }

    fn note_session(&mut self, id: &str, round: Option<&str>) {
        self.session_id = id.into();
        self.round_id = round.filter(|r| !r.is_empty()).map(String::from).unwrap_or_else(|| format!("ro_{id}_0"));
        self.attached = true;
    }

    fn reset(&mut self) {
        self.attached = false;
        self.session_id.clear();
        self.round_id.clear();
    }

    fn attach_packet(&self) -> Result<Vec<u8>> {
        let reqt = now_ms().to_string();
        let asr = json!({
            "body": {"bitDepth": "16", "channel": "mono", "format": "pcm", "maxEndSilence": "180000",
                     "maxStartSilence": "180000", "sampleRate": "16000", "type": "manualStreamStop"},
            "chid": self.auth.chid,
            "header": {"clt-acs-reqt": reqt, "ai_polish_mode": "off"},
            "param": {},
            "route": "/app/live/init",
        });
        let pipe = json!({
            "biz_data": {}, "biz_id": "ai_command", "chat_client": "native", "client_tm": reqt,
            "endpoint_config": {}, "from": "kkframenew_quark_asr", "scene": "voice_input_assistant",
            "ai_polish_mode": "off",
        });
        Ok(PBuf::new()
            .s(1, "/voice_assistant/channel/attach")
            .s(2, &self.auth.chid)
            .kv(3, "clt-acs-reqt", &reqt)
            .kv(5, "asrConfig", &asr.to_string())
            .kv(5, "pipelineContext", &pipe.to_string())
            .kv(5, "trigger", "local_device")
            .0)
    }

    fn base(&self, route: &str) -> PBuf {
        PBuf::new()
            .s(1, route)
            .s(2, &self.auth.chid)
            .kv(3, "clt-acs-reqt", &now_ms().to_string())
            .kv(4, "roundId", &self.round_id)
            .kv(4, "sessionId", &self.session_id)
    }

    fn asr_send(&self, pcm: &[u8]) -> Vec<u8> {
        let audio = PBuf::new().s(1, "audio").s(2, "pcm").b(3, pcm);
        self.base("/voice_assistant/channel/asr/send").kv(5, "streamInputState", "process").m(6, audio).0
    }

    fn asr_complete(&self) -> Vec<u8> {
        self.base("/voice_assistant/channel/asr/complete").0
    }
}

/// 本机 UTDID 只生成一次落盘，会话 chid 每次新开
#[derive(Serialize, Deserialize)]
struct QwenDevice {
    utdid: String,
}

impl QwenDevice {
    fn load() -> String {
        let file = data_file("qwen.json");
        if let Some(d) = std::fs::read(&file).ok().and_then(|b| serde_json::from_slice::<QwenDevice>(&b).ok()) {
            if !d.utdid.is_empty() {
                return d.utdid;
            }
        }
        let utdid = format!("VK{}", &uuid::Uuid::new_v4().simple().to_string().to_uppercase()[..20]);
        let _ = std::fs::write(&file, serde_json::to_vec(&QwenDevice { utdid: utdid.clone() }).unwrap());
        utdid
    }

    fn reset() {
        let _ = std::fs::remove_file(data_file("qwen.json"));
    }
}

struct QwenAuth {
    ut: String,
    chid: String,
    reqt: String,
    sign: String,
}

impl QwenAuth {
    fn make() -> Result<Self> {
        let utdid = QwenDevice::load();
        let enc = cbc::Encryptor::<aes::Aes128>::new(AES_KEY.into(), AES_KEY.into()).encrypt_padded_vec_mut::<Pkcs7>(utdid.as_bytes());
        let mut packed = vec![0x4e, 0xa4];
        packed.extend(enc);
        let ut = base64::engine::general_purpose::STANDARD.encode(packed);
        let chid = format!("{}_1", uuid::Uuid::new_v4());
        let reqt = now_ms().to_string();
        let mut mac = Hmac::<sha1::Sha1>::new_from_slice(HMAC_KEY)?;
        mac.update(format!("{ut}{VE}{chid}{reqt}").as_bytes());
        let sign = format!("4ea4{}", hex::encode(mac.finalize().into_bytes()));
        Ok(Self { ut, chid, reqt, sign })
    }

    fn headers(&self) -> Vec<(&'static str, String)> {
        vec![
            ("clt-acs-ut", qenc(&self.ut)),
            ("clt-acs-ve", VE.into()),
            ("clt-acs-kp", String::new()),
            ("clt-acs-reqt", self.reqt.clone()),
            ("clt-acs-wsgnver", "1".into()),
            ("clt-acs-request-params", "chid".into()),
            ("clt-acs-sign", self.sign.clone()),
            ("clt-acs-caer", "tlbe".into()),
            ("x-wpk-reqid", self.chid.clone()),
        ]
    }

    fn query(&self) -> String {
        format!(
            "chid={}&biz_id=ai_qwen_input&from=kkframenew_quark_asr&uc_param_str=vepffrprsvchut&ut={}&ve={VE}&pf=8002&pr=qwen&fr=mac&sv=release&ch=qianwen-ime",
            self.chid,
            qenc(&self.ut)
        )
    }
}

fn qenc(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}
