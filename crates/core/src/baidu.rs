use crate::util::{data_file, rand_lower};
use crate::{opus, Audio, Engine, Partial};
use anyhow::{anyhow, bail, Result};
use bytes::Bytes;
use flate2::write::DeflateEncoder;
use flate2::{Crc, Compression};
use futures_util::stream;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;
use uuid::Uuid;

const HOST: &str = "https://vse.baidu.com/v2";
const VER: &str = "4.8.3.285";
const PID: i64 = 597;
const KEY: &str = "com.baidu.input_nlu";
const APP: &str = "com.baidu.input";
const PACK: usize = 8;

/// 百度输入法云端 ASR：HTTP 分块 up/down + deflate JSON 首包 + Opus
#[derive(Default)]
pub struct BaiduEngine;

fn pkt(typ: u8, payload: &[u8]) -> Vec<u8> {
    let n = payload.len() + 1;
    let mut v = Vec::with_capacity(4 + n);
    v.extend_from_slice(&(n as u32).to_le_bytes());
    v.push(typ);
    v.extend_from_slice(payload);
    v
}

fn start_pkt(sn: &str, cuid: &str) -> Result<Vec<u8>> {
    let j = json!({
        "key": KEY,
        "appid": PID,
        "pam": "",
        "vp_pam": "",
        "wwd": "",
        "ctl": "{\"s_wake\":true,\"s_sdk_vad_mode\":1,\"s_link_switch\":\"ws\"}",
        "cuid": cuid,
        "sdk_vad_mode": 0,
        "pfm": "",
        "ver": VER,
        "use_mapping": 0,
        "map_multi_info": "",
        "pid": PID,
        "smr": 16000,
        "trig": 0,
        "enable_combined_tts": 1,
        "sn": sn,
        "lsn": sn,
        "rgn_id": "",
        "app": APP,
        "offline_auth_ctrl": 0,
        "cid": 0,
        "prop_list": [10005],
        "debug": 0,
        "msn": sn,
        "crt": 0,
        "dep": "{\"pkg\":\"com.apple.mobilenotes\"}",
        "cookie": "",
        "masr": 0,
        "midx": 1,
        "fun": 537198592,
    });
    let raw = serde_json::to_vec_pretty(&j)?;
    // 官方用 tab 缩进；serde pretty 是两空格，服务端不校验空白
    let mut enc = DeflateEncoder::new(Vec::new(), Compression::best());
    enc.write_all(&raw)?;
    let defl = enc.finish()?;
    let mut crc = Crc::new();
    crc.update(&raw);
    let mut payload = Vec::with_capacity(10 + defl.len() + 8);
    payload.extend_from_slice(b"u{");
    payload.extend_from_slice(&[8, 0, 0, 0, 0, 0, 0, 3]);
    payload.extend_from_slice(&defl);
    payload.extend_from_slice(&crc.sum().to_le_bytes());
    payload.extend_from_slice(&(raw.len() as u32).to_le_bytes());
    Ok(pkt(0, &payload))
}

fn word(v: &Value) -> Option<String> {
    v["result"]["word"].as_array()?.first()?.as_str().map(str::to_string)
}

#[derive(Default)]
struct Transcript {
    text: String,
    err: Option<String>,
    done: bool,
}

fn on_frame(t: &Mutex<Transcript>, typ: u8, body: &[u8], partial: &Partial) {
    if typ == 244 || typ == 243 || body.is_empty() {
        if typ == 243 {
            t.lock().unwrap().done = true;
        }
        return;
    }
    let Ok(v) = serde_json::from_slice::<Value>(body) else { return };
    if let Some(w) = word(&v) {
        let mut g = t.lock().unwrap();
        if w != g.text {
            g.text = w.clone();
            drop(g);
            partial(&w);
        }
    }
    let err_no = v["err_no"].as_i64().unwrap_or(0);
    let kind = v["result_type"].as_str().unwrap_or("");
    let mut g = t.lock().unwrap();
    if err_no != 0 && g.text.is_empty() {
        g.err = Some(v["err_msg"].as_str().unwrap_or("识别失败").to_string());
        g.done = true;
    }
    if kind == "TS_RESULT_TYPE_ONEBSET" {
        g.done = true;
    }
}

#[derive(Serialize, Deserialize, Default)]
struct Dev {
    cuid: String,
}

impl Dev {
    fn load() -> Self {
        let p = data_file("baidu.json");
        if let Ok(s) = std::fs::read_to_string(&p) {
            if let Ok(d) = serde_json::from_str::<Dev>(&s) {
                if !d.cuid.is_empty() {
                    return d;
                }
            }
        }
        let hex = Uuid::new_v4().simple().to_string().to_uppercase();
        let d = Dev { cuid: format!("{}|{}", hex, rand_lower(9).to_uppercase()) };
        let _ = std::fs::write(p, serde_json::to_string(&d).unwrap_or_default());
        d
    }
}

#[async_trait::async_trait]
impl Engine for BaiduEngine {
    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        let sn = Uuid::new_v4().to_string();
        let cuid = Dev::load().cuid;
        let client = reqwest::Client::builder().tcp_nodelay(true).http1_only().build()?;
        let down = client
            .post(format!("{HOST}/down?sn={sn}"))
            .header("Content-Type", "text/json")
            .header("Accept-Encoding", "identity")
            .send();

        let (tx, rx) = mpsc::unbounded_channel::<Bytes>();
        let stream = stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|b| (Ok::<_, std::io::Error>(b), rx))
        });
        let up = client
            .post(format!("{HOST}/up?sn={sn}"))
            .header("Content-Type", "application/octet-stream")
            .body(reqwest::Body::wrap_stream(stream))
            .send();

        tx.send(Bytes::from(start_pkt(&sn, &cuid)?)).map_err(|_| anyhow!("百度上传中断"))?;

        let t = Arc::new(Mutex::new(Transcript::default()));
        let t2 = t.clone();
        let down_task = tokio::spawn(async move {
            let mut resp = down.await.map_err(|e| anyhow!("百度下行失败：{e}"))?;
            if !resp.status().is_success() {
                bail!("百度下行 HTTP {}", resp.status());
            }
            let mut buf = Vec::new();
            while let Some(chunk) = resp.chunk().await.map_err(|e| anyhow!("{e}"))? {
                buf.extend_from_slice(&chunk);
                loop {
                    if buf.len() < 4 {
                        break;
                    }
                    let n = u32::from_le_bytes(buf[..4].try_into().unwrap()) as usize;
                    if n == 0 || n > 1_000_000 || buf.len() < 4 + n {
                        break;
                    }
                    let fr = buf[4..4 + n].to_vec();
                    buf.drain(..4 + n);
                    on_frame(&t2, fr[0], &fr[1..], &partial);
                }
                if t2.lock().unwrap().done {
                    break;
                }
            }
            Ok::<(), anyhow::Error>(())
        });

        let up_task = tokio::spawn(async move {
            up.await.map_err(|e| anyhow!("百度上行失败：{e}"))
        });

        tx.send(Bytes::from(pkt(5, br#"{"realtime-log":"INPUT&a1&13.3.16.2&0&com.baidu.input"}"#))).ok();

        let mut enc = opus::Opus::baidu()?;
        let mut batch = Vec::new();
        let mut first = true;
        let mut n = 0usize;
        while let Some(frame) = audio.recv().await {
            batch.extend_from_slice(&enc.encode_bd(&frame)?);
            n += 1;
            if n >= PACK {
                let mut payload = Vec::with_capacity(4 + batch.len());
                if first {
                    first = false;
                    payload.extend_from_slice(&[0x44, 0, 0, 0]);
                }
                payload.append(&mut batch);
                tx.send(Bytes::from(pkt(1, &payload))).ok();
                n = 0;
            }
        }
        if !batch.is_empty() {
            tx.send(Bytes::from(pkt(1, &batch))).ok();
        }
        tx.send(Bytes::from(pkt(9, &[]))).ok();
        tx.send(Bytes::from(pkt(7, &[]))).ok();
        drop(tx);

        let _ = tokio::time::timeout(Duration::from_secs(12), up_task).await;
        let _ = tokio::time::timeout(Duration::from_secs(8), down_task).await;
        let g = t.lock().unwrap();
        if let Some(e) = &g.err {
            if g.text.is_empty() {
                bail!("百度{e}");
            }
        }
        Ok(g.text.clone())
    }
}
