use crate::util::{data_file, now_ms};
use crate::{opus, Audio, Engine, Partial};
use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

const HOST: &str = "https://ltalk.speech.sogou.com/index.lt";
const PACK: usize = 10;
const TYPE_NO: i32 = 20512;
const VER: i32 = 1258;
const PKG: &str = "com.sogou.sogouinput";

/// 搜狗输入法云端 ASR：HTTP POST + `opus`+LE32 帧
#[derive(Default)]
pub struct SogouEngine;

fn wrap(op: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(8 + op.len());
    v.extend_from_slice(b"opus");
    v.extend_from_slice(&(op.len() as u32).to_le_bytes());
    v.extend_from_slice(op);
    v
}

fn word(v: &Value) -> Option<String> {
    v["result"]
        .as_array()?
        .first()?
        .get("vs")?
        .as_array()?
        .first()?
        .get("s")?
        .as_str()
        .map(str::to_string)
}

#[derive(Serialize, Deserialize, Default)]
struct Dev {
    imei: String,
}

impl Dev {
    fn load() -> Self {
        let p = data_file("sogou.json");
        if let Ok(s) = std::fs::read_to_string(&p) {
            if let Ok(d) = serde_json::from_str::<Dev>(&s) {
                if !d.imei.is_empty() {
                    return d;
                }
            }
        }
        let d = Dev { imei: Uuid::new_v4().to_string().to_uppercase() };
        let _ = std::fs::write(p, serde_json::to_string(&d).unwrap_or_default());
        d
    }
}

async fn post(client: &reqwest::Client, imei: &str, start: u64, seq: u64, blob: &[u8]) -> Result<Value> {
    let url = format!(
        "{HOST}?area=0&base_no=&cancel=0&imei_no={imei}&start_time={start}&sequence_no={seq}&voice_length={}&result_amount=5&type_no={TYPE_NO}&v={VER}&package_name={PKG}&action_type=0&input_type=0&partial=1&token=0&net_type=wifi&action_time={}&entry_type=0&contactkey=%7C%7C{imei}%7C%7C&chuosign=0&audio_type=1",
        blob.len(),
        now_ms()
    );
    let mut body = Vec::with_capacity(14 + blob.len());
    body.extend_from_slice(b"voice_content=");
    body.extend_from_slice(blob);
    Ok(client.post(url).body(body).send().await?.json().await?)
}

#[async_trait::async_trait]
impl Engine for SogouEngine {
    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        let imei = Dev::load().imei;
        let start = now_ms();
        let client = reqwest::Client::builder().tcp_nodelay(true).build()?;
        let mut enc = opus::Opus::new(opus::AUDIO, 16000, 5)?;
        let mut batch = Vec::new();
        let mut n = 0usize;
        let mut seq = 0u64;
        let mut text = String::new();

        while let Some(frame) = audio.recv().await {
            batch.extend_from_slice(&wrap(&enc.encode(&frame)?));
            n += 1;
            if n >= PACK {
                let v = post(&client, &imei, start, seq, &batch).await?;
                if let Some(w) = word(&v) {
                    if w != text {
                        text = w;
                        partial(&text);
                    }
                }
                let st = v["status"].as_i64().unwrap_or(0);
                if st < 0 && text.is_empty() {
                    bail!("搜狗{}", v["message"].as_str().unwrap_or("识别失败"));
                }
                batch.clear();
                n = 0;
                seq += 1;
            }
        }
        if !batch.is_empty() {
            let v = post(&client, &imei, start, seq, &batch).await?;
            if let Some(w) = word(&v) {
                text = w;
            }
            let st = v["status"].as_i64().unwrap_or(0);
            if st < 0 && text.is_empty() {
                bail!("搜狗{}", v["message"].as_str().unwrap_or("识别失败"));
            }
        }
        Ok(text)
    }
}
