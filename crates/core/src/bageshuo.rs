use crate::account::Login;
use crate::util::{data_file, now_ms};
use crate::ws::{self, Update, Ws};
use crate::{Audio, Engine, Partial};
use anyhow::{anyhow, bail, Result};
use futures_util::future::BoxFuture;
use futures_util::SinkExt;
use md5::{Digest, Md5};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;

/// 有道账号登录后写在 .youdao.com 的 Cookie：DICT_PERS 单独可用，否则要 DICT_SESS 与 DICT_LOGIN
pub static LOGIN: Login = Login {
    id: "bageshuo",
    page: "https://shared.youdao.com/dict/application/bageshuo-login-h5/index.html",
    domain: "youdao.com",
    cookies: &[&["DICT_PERS"], &["DICT_SESS", "DICT_LOGIN"]],
    check,
};

const BASE: &str = "https://dict-typeless.youdao.com";
const VERSION: &str = "1.0.30";
const UA: &str = "bageshuo/1.0.30";
const KEY_ID: &str = "typeless_mac_main";
/// 客户端内置的签名密钥
const SECRET: &str = "1TNWxQEtUtTg1XkhvJvQJl84TmtLXmCe";
const MODEL: &str = "Mac14,2";

/// 叭哥说（网易有道）云端识别：登录 Cookie + MD5 签名换一次性 ticket，WebSocket 上 JSON 控制帧 + PCM 二进制帧。
/// 服务端定稿后还会做 AI 润色，润色会改写内容、插入换行，这里只取识别定稿
#[derive(Default)]
pub struct BageshuoEngine;

fn check(cookie: &str) -> BoxFuture<'_, Result<()>> {
    Box::pin(async move { ticket(cookie).await.map(drop) })
}

/// 本机设备号只生成一次落盘，mid / imei / yduuid 共用
fn device() -> String {
    let file = data_file("bageshuo.json");
    let saved = std::fs::read(&file).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    if let Some(id) = saved.as_ref().and_then(|v| v["device"].as_str()).filter(|s| !s.is_empty()) {
        return id.into();
    }
    let id = uuid::Uuid::new_v4().to_string();
    let _ = std::fs::write(&file, json!({ "device": id }).to_string());
    id
}

/// 设备号逐字节 h = h*31 + b（u32 溢出回绕）后模 10
fn abtest(device: &str) -> u32 {
    device.bytes().fold(0u32, |h, b| h.wrapping_mul(31).wrapping_add(b as u32)) % 10
}

/// 14 个通用参数按键名排序拼成 `k=v&…&key=密钥` 取 MD5 作 sign，参与签名的键名逗号连接作 pointParam
fn signed_query(device: &str, now: u64) -> Vec<(&'static str, String)> {
    let mut q: Vec<(&'static str, String)> = vec![
        ("product", "typeless".into()),
        ("appVersion", VERSION.into()),
        ("client", "mac".into()),
        ("mid", device.into()),
        ("vendor", "direct".into()),
        ("screen", "1920x1080".into()),
        ("model", MODEL.into()),
        ("imei", device.into()),
        ("network", "wifi".into()),
        ("keyfrom", format!("typeless.{VERSION}.mac")),
        ("abtest", abtest(device).to_string()),
        ("yduuid", device.into()),
        ("keyid", KEY_ID.into()),
        ("mysticTime", now.to_string()),
    ];
    q.sort_by_key(|(k, _)| *k);
    let plain = q.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("&");
    let sign = hex::encode(Md5::digest(format!("{plain}&key={SECRET}")));
    let point = q.iter().map(|(k, _)| *k).collect::<Vec<_>>().join(",");
    q.push(("sign", sign));
    q.push(("pointParam", point));
    q.extend([
        ("generationStreaming", "true".into()),
        ("osName", "macOS".into()),
        ("osVersion", "14.0".into()),
        ("architecture", "arm64".into()),
        ("chip", String::new()),
        ("deviceModel", MODEL.into()),
    ]);
    q
}

/// 申请一次性 ticket，返回带 ticket 的 WebSocket 地址
async fn ticket(cookie: &str) -> Result<String> {
    let resp = reqwest::Client::new()
        .post(format!("{BASE}/api/v1/realtime/tickets"))
        .query(&signed_query(&device(), now_ms()))
        .header("Cookie", cookie)
        .header("User-Agent", UA)
        .json(&json!({ "protocolVersion": 1, "capabilities": { "generationStreaming": true } }))
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| anyhow!("叭哥说连接失败：{e}"))?;
    let status = resp.status();
    let v: Value = resp.json().await.unwrap_or_default();
    if status.as_u16() == 401 {
        bail!("叭哥说登录已失效，请重新登录");
    }
    let d = if v["data"].is_object() { &v["data"] } else { &v };
    match d["websocketUrl"].as_str().filter(|s| status.is_success() && !s.is_empty()) {
        Some(url) => official(url).ok_or_else(|| anyhow!("叭哥说返回的识别地址不是有道官方域名")),
        None => bail!("叭哥说获取识别会话失败：{}（{}）", v["message"].as_str().or(v["msg"].as_str()).unwrap_or("未知错误"), status.as_u16()),
    }
}

/// 识别连接会带上登录 Cookie，只连有道官方域名。返回解析后的地址，连接与校验用同一份
fn official(url: &str) -> Option<String> {
    let u = reqwest::Url::parse(url).ok()?;
    let host = u.host_str()?;
    (u.scheme() == "wss" && (host == "youdao.com" || host.ends_with(".youdao.com"))).then(|| u.into())
}

fn error(v: &Value) -> String {
    let p = &v["payload"];
    format!("叭哥说 {}（{}）", p["message"].as_str().unwrap_or("识别失败"), p["code"].as_str().unwrap_or("-"))
}

/// 等到指定类型的消息，跳过 utterance.preparing 等过程通知
async fn wait(ws: &mut Ws, ty: &str) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let d = ws::recv(ws, deadline.saturating_duration_since(Instant::now())).await.map_err(|e| anyhow!("叭哥说 {e}"))?;
        let Ok(v) = serde_json::from_slice::<Value>(&d) else { continue };
        if v["type"] == ty {
            return Ok(());
        }
        if v["type"] == "error" {
            bail!(error(&v));
        }
    }
}

async fn open(cookie: &str, uid: &str) -> Result<Ws> {
    let url = ticket(cookie).await?;
    let mut ws = ws::connect(&url, &[("Cookie", cookie), ("User-Agent", UA)]).await.map_err(|e| anyhow!("叭哥说 {e}"))?;
    wait(&mut ws, "connection.ready").await?;
    // operation 只接受 POLISH / TRANSLATE
    let start = json!({
        "v": 1,
        "type": "utterance.start",
        "utteranceId": uid,
        "payload": { "operation": "POLISH", "asrLang": "zh-CHS", "preRollPcmBase64": "" },
    });
    ws.send(Message::Text(start.to_string())).await?;
    wait(&mut ws, "utterance.ready").await?;
    Ok(ws)
}

#[async_trait::async_trait]
impl Engine for BageshuoEngine {
    async fn run(&self, audio: Audio, partial: Partial) -> Result<String> {
        let cookie = LOGIN.get();
        if cookie.is_empty() {
            bail!("叭哥说未登录，请在设置的识别渠道里登录");
        }
        let uid = uuid::Uuid::new_v4().to_string();
        let ws = open(&cookie, &uid).await?;
        let end = json!({ "v": 1, "type": "utterance.end", "utteranceId": uid });
        // fullText 是从开头到当前的整段文本。没有有效语音时定稿的 fullText 为空
        ws::recognize(ws, audio, end.to_string(), partial, |v| match v["type"].as_str().unwrap_or("") {
            "transcript.partial" => Update::Text(v["payload"]["fullText"].as_str().unwrap_or("").into()),
            "transcript.final" => Update::Done(v["payload"]["fullText"].as_str().map(Into::into)),
            "error" => Update::Error(error(v)),
            _ => Update::Skip,
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signature_matches_official_client() {
        let q = signed_query("3f2a7c1e-9b4d-4e8a-a1c2-5d6e7f809a1b", 1_700_000_000_000);
        let get = |k: &str| q.iter().find(|(n, _)| *n == k).map(|(_, v)| v.as_str()).unwrap();
        assert_eq!(get("abtest"), "6");
        assert_eq!(get("sign"), "7bb9c7bc03e44cd83603facb55604fba");
        assert_eq!(get("pointParam"), "abtest,appVersion,client,imei,keyfrom,keyid,mid,model,mysticTime,network,product,screen,vendor,yduuid");
    }

    #[test]
    fn only_connects_to_youdao() {
        assert_eq!(official("wss://dict-typeless.youdao.com/ws?ticket=1").as_deref(), Some("wss://dict-typeless.youdao.com/ws?ticket=1"));
        assert!(official("ws://dict-typeless.youdao.com/ws").is_none());
        assert!(official("wss://youdao.com.evil.com/ws").is_none());
        assert!(official("wss://evil.com/youdao.com").is_none());
        assert!(official("wss://evilyoudao.com/ws").is_none());
        assert!(official("wss://a.youdao.com@evil.com/ws").is_none());
    }
}
