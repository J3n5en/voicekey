use crate::ws::{self, Ws};
use crate::{Audio, Engine, Partial};
use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
use anyhow::{anyhow, bail, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use futures_util::{SinkExt, StreamExt};
use rand::RngCore;
use rsa::pkcs8::DecodePublicKey;
use rsa::{Oaep, RsaPublicKey};
use serde_json::{json, Value};
use sha2::Sha256;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

const HOST: &str = "srss.speech.sogou.com";
const PATH: &str = "/srss/v1/speech/streaming_recognize";
const PRODUCT: &str = "com.tencent.inputmethod.chatterfly";
const PRODUCT_VERSION: &str = "1.0.9.13509";

/// 服务端下发的会话密钥加密公钥（3072 位，DER SubjectPublicKeyInfo）
const PUBKEY: &[u8] = include_bytes!("chatterfly_pub.der");

/// Chatterfly（元宝输入法）云端流式识别：wss + 加密 config 首帧 + 裸 PCM 二进制帧
#[derive(Default)]
pub struct ChatterflyEngine;

fn hex32() -> String {
    let mut b = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut b);
    hex::encode(b)
}

fn language() -> String {
    std::env::var("CHATTERFLY_LANG").unwrap_or_else(|_| "zh-cmn-Hans-CN".to_string())
}

fn config(token: &str) -> Value {
    // audio_id / audio_slice_id 必须是 32 位 hex，否则服务端回 invalid audio info
    let dev = json!({
        "device_category": "mac",
        "device_uuid": hex32(),
        "device_aid": hex32(),
        "device_qid": hex32(),
    });
    let mut cfg = json!({
        "config": {
            "encoding": "LINEAR16",
            "language_code": language(),
            "model": "default",
            "punctuation_mode": "NORMAL_PUNCTUATION",
            "convert_number": true,
            "metadata": {
                // client_info 缺失或结构不符 -> invalid client info
                "client_info": {
                    "product_category": "ime",
                    "product_id": PRODUCT,
                    "product_version": PRODUCT_VERSION,
                },
                "sdk_info": { "sdk_category": "mac", "sdk_id": "nsrss", "sdk_version": "1.0.0" },
                "record_device_info": dev,
                "record_os_info": { "os_category": "mac", "os_id": "mac", "os_version": "14.0" },
                "host_device_info": dev,
                "host_os_info": { "os_category": "mac", "os_id": "mac", "os_version": "14.0" },
                "user_info": { "user_category": "normal", "user_id": "0" },
                "audio_info": { "audio_id": hex32(), "audio_slice_id": hex32() },
                "network_info": { "network_type": "wifi", "network_proxy_type": "none" },
                "runtime_info": {
                    "consumer_product_id": PRODUCT,
                    "consumer_purpose": "ime",
                    "consumer_input_type": "voice",
                },
            },
        },
        "interim_results": true,
        // 必须关闭：开启后服务端用 VAD 自行判句尾，用户按下麦克风到开口之间的
        // 前导静音会被当成「一句话说完了」，直接回 END_OF_SINGLE_UTTERANCE 并断开连接。
        // 由我们发 "{}" 决定何时收尾（服务端仍会返回 is_final 结果和标点）。
        "single_utterance": false,
    });
    if !token.is_empty() {
        cfg["config"]["auth_token"] = json!(token);
    }
    cfg
}

struct Sealed {
    body: String,
    sec: String,
    vec: String,
}

/// AES-256-CBC(PKCS7) 加密 config，AES 密钥用 RSA-OAEP(SHA256) 封装
fn seal(plain: &[u8]) -> Result<Sealed> {
    let mut key = [0u8; 32];
    let mut iv = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut key);
    rand::thread_rng().fill_bytes(&mut iv);
    let body = cbc::Encryptor::<aes::Aes256>::new((&key).into(), (&iv).into())
        .encrypt_padded_vec_mut::<Pkcs7>(plain);
    let pubkey = RsaPublicKey::from_public_key_der(PUBKEY).map_err(|e| anyhow!("公钥解析失败：{e}"))?;
    let sec = pubkey
        .encrypt(&mut rand::thread_rng(), Oaep::new::<Sha256>(), &key)
        .map_err(|e| anyhow!("密钥封装失败：{e}"))?;
    Ok(Sealed { body: B64.encode(body), sec: B64.encode(sec), vec: B64.encode(iv) })
}

/// 拼出本次响应携带的整句文本
fn transcript(v: &Value) -> String {
    let Some(rs) = v["results"].as_array() else { return String::new() };
    rs.iter()
        .filter_map(|r| Some(r["alternatives"].as_array()?.first()?["transcript"].as_str()?.to_string()))
        .collect::<Vec<_>>()
        .join("")
}

fn is_final(v: &Value) -> bool {
    v["results"]
        .as_array()
        .map(|rs| rs.iter().any(|r| r["is_final"].as_bool().unwrap_or(false)))
        .unwrap_or(false)
}

fn server_error(v: &Value) -> Option<String> {
    let e = &v["error"];
    if e.is_null() {
        return None;
    }
    let code = e["code"].as_i64().unwrap_or(-1);
    let msg = e["message"].as_str().unwrap_or("识别失败");
    Some(format!("Chatterfly {msg}（{code}）"))
}

async fn open(token: &str) -> Result<(Ws, String)> {
    let cfg = config(token);
    let sealed = seal(serde_json::to_vec(&cfg)?.as_slice())?;
    let url = format!("wss://{HOST}{PATH}");
    let mut headers = vec![
        ("X-Srss-Cipher-Key-Type", "1"),
        ("X-Srss-Cipher-Key-Sec", sealed.sec.as_str()),
        ("X-Srss-Cipher-Key-Vec", sealed.vec.as_str()),
    ];
    let auth;
    if !token.is_empty() {
        auth = format!("Bearer {token}");
        headers.push(("Authorization", auth.as_str()));
    }
    let ws = ws::connect(&url, &headers).await?;
    Ok((ws, sealed.body))
}

#[async_trait::async_trait]
impl Engine for ChatterflyEngine {
    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        let token = std::env::var("CHATTERFLY_TOKEN").unwrap_or_default();
        let (ws, body) = open(&token).await?;
        let (mut sink, mut stream) = ws.split();
        sink.send(Message::Text(body.into())).await?;

        let mut text = String::new();
        let mut sent = 0usize;
        let mut closed = false;
        // 空闲超时：服务端每次出字即刷新，长语音不会因为总时长被截断
        let mut deadline = tokio::time::Instant::now() + Duration::from_secs(30);

        loop {
            tokio::select! {
                biased;
                frame = audio.recv(), if !closed => match frame {
                    Some(pcm) => {
                        let bytes: Vec<u8> = pcm.iter().flat_map(|s| s.to_le_bytes()).collect();
                        sent += pcm.len();
                        sink.send(Message::Binary(bytes.into())).await?;
                    }
                    None => {
                        closed = true;
                        // 结束信号：文本帧 "{}"，服务端据此返回 is_final（带标点）
                        sink.send(Message::Text("{}".into())).await?;
                    }
                },
                msg = stream.next() => {
                    let chunk = match ws::data(msg) {
                        Ok(Some(d)) => d,
                        Ok(None) => continue,
                        Err(e) => {
                            if text.is_empty() { return Err(e); }
                            break;
                        }
                    };
                    let Ok(v) = serde_json::from_slice::<Value>(&chunk) else { continue };
                    deadline = tokio::time::Instant::now() + Duration::from_secs(30);
                    if let Some(e) = server_error(&v) { return Err(anyhow!(e)); }
                    let t = transcript(&v);
                    if t != text {
                        text = t;
                        partial(&text);
                    }
                    if is_final(&v) {
                        break;
                    }
                }
                _ = tokio::time::sleep_until(deadline) => {
                    if text.is_empty() { bail!("识别超时"); }
                    break;
                }
            }
        }
        let _ = sink.close().await;
        if text.is_empty() && sent == 0 {
            bail!("没有采集到音频");
        }
        Ok(text)
    }
}
