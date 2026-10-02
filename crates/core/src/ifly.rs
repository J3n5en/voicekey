use crate::ws;
use crate::{Audio, Engine, Partial};
use anyhow::{bail, Result};
use base64::Engine as _;
use futures_util::SinkExt;
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
use std::collections::BTreeMap;
use std::time::Duration;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;

const HOST: &str = "100ime-iat-api.xfyun.cn";
const PATH: &str = "/v2/iat";
const APPID: &str = "100IME";
const API_KEY: &str = "15461402826c8360ebcf1270cbba88e5";
const API_SECRET: &str = "sH8v2wSSxxHTy1UNfN6dFaSqVjlmR7BB";
const CHUNK: usize = 1280;

/// 讯飞输入法云端 ASR：IAT WebSocket + HMAC-SHA256
#[derive(Default)]
pub struct IflyEngine;

fn enc(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 8);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => o.push(b as char),
            _ => o.push_str(&format!("%{b:02X}")),
        }
    }
    o
}

fn http_gmt() -> String {
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
    let z = t.div_euclid(86400);
    let tod = t.rem_euclid(86400);
    let h = tod / 3600;
    let m = (tod % 3600) / 60;
    let s = tod % 60;
    let wday = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"][z.rem_euclid(7) as usize];
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = mp + if mp < 10 { 3 } else { -9 };
    let y = y + i64::from(mo <= 2);
    let mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][(mo - 1) as usize];
    format!("{wday}, {d:02} {mon} {y} {h:02}:{m:02}:{s:02} GMT")
}

fn auth_url() -> Result<String> {
    let date = http_gmt();
    let origin = format!("host: {HOST}\ndate: {date}\nGET {PATH} HTTP/1.1");
    let mut mac = Hmac::<Sha256>::new_from_slice(API_SECRET.as_bytes())?;
    mac.update(origin.as_bytes());
    let sig = base64::engine::general_purpose::STANDARD.encode(mac.finalize().into_bytes());
    let auth_origin = format!(r#"api_key="{API_KEY}", algorithm="hmac-sha256", headers="host date request-line", signature="{sig}""#);
    let auth = base64::engine::general_purpose::STANDARD.encode(auth_origin);
    Ok(format!("wss://{HOST}{PATH}?authorization={}&date={}&host={HOST}", enc(&auth), enc(&date)))
}

fn pgs_text(segs: &mut BTreeMap<i64, String>, v: &Value) -> Option<String> {
    let r = v.get("data")?.get("result")?;
    let sn = r.get("sn")?.as_i64()?;
    let mut t = String::new();
    if let Some(ws) = r.get("ws").and_then(Value::as_array) {
        for w in ws {
            if let Some(s) = w.get("cw").and_then(Value::as_array).and_then(|a| a.first()).and_then(|c| c.get("w")).and_then(Value::as_str) {
                t.push_str(s);
            }
        }
    }
    if r.get("pgs").and_then(Value::as_str) == Some("rpl") {
        if let Some(rg) = r.get("rg").and_then(Value::as_array) {
            if rg.len() == 2 {
                let a = rg[0].as_i64().unwrap_or(0);
                let b = rg[1].as_i64().unwrap_or(0);
                segs.retain(|k, _| *k < a || *k > b);
            }
        }
    }
    segs.insert(sn, t);
    Some(segs.values().cloned().collect())
}

fn frame(status: i32, audio: &[u8], first: bool) -> String {
    let audio = base64::engine::general_purpose::STANDARD.encode(audio);
    if first {
        json!({
            "common": {"app_id": APPID},
            "business": {"language":"zh_cn","domain":"iat","accent":"mandarin","vad_eos":3000,"dwa":"wpgs","nunum":1,"ptt":1},
            "data": {"status": status, "format":"audio/L16;rate=16000", "encoding":"raw", "audio": audio}
        })
        .to_string()
    } else {
        json!({"data": {"status": status, "format":"audio/L16;rate=16000", "encoding":"raw", "audio": audio}}).to_string()
    }
}

#[async_trait::async_trait]
impl Engine for IflyEngine {
    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        let mut ws = ws::connect(&auth_url()?, &[]).await?;
        let mut segs = BTreeMap::new();
        let mut text = String::new();
        let mut first = true;
        let mut buf = Vec::new();
        let mut last = false;

        let mut apply = |raw: &[u8], text: &mut String| -> Result<bool> {
            let v: Value = serde_json::from_slice(raw)?;
            let code = v["code"].as_i64().unwrap_or(-1);
            if code != 0 {
                bail!("讯飞{}", v["message"].as_str().unwrap_or("识别失败"));
            }
            if let Some(w) = pgs_text(&mut segs, &v) {
                if w != *text {
                    *text = w;
                    partial(text);
                }
            }
            Ok(v["data"]["status"].as_i64() == Some(2))
        };

        while let Some(frame_pcm) = audio.recv().await {
            buf.extend(frame_pcm.iter().flat_map(|s| s.to_le_bytes()));
            while buf.len() >= CHUNK {
                let chunk: Vec<u8> = buf.drain(..CHUNK).collect();
                ws.send(Message::Text(frame(if first { 0 } else { 1 }, &chunk, first))).await?;
                first = false;
            }
            while let Ok(Some(d)) = ws::recv_opt(&mut ws, Duration::from_millis(1)).await {
                last = apply(&d, &mut text)?;
            }
        }
        if !buf.is_empty() {
            ws.send(Message::Text(frame(if first { 0 } else { 1 }, &buf, first))).await?;
            first = false;
        }
        ws.send(Message::Text(frame(2, &[], first))).await?;
        let deadline = Instant::now() + Duration::from_millis(2500);
        while !last && Instant::now() < deadline {
            if let Some(d) = ws::recv_opt(&mut ws, deadline - Instant::now()).await? {
                last = apply(&d, &mut text)?;
            }
        }
        if text.is_empty() {
            bail!("讯飞没有识别文本");
        }
        Ok(text)
    }
}
