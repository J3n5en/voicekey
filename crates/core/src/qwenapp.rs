use crate::account::Login;
use crate::ws::{self, Update, Ws};
use crate::{Audio, Engine, Partial};
use anyhow::{anyhow, bail, Result};
use futures_util::future::BoxFuture;
use futures_util::SinkExt;
use serde_json::{json, Value};
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::Message;

/// 千问网页登录后写在 .qianwen.com 的 tongyi_sso_ticket，有效期约一年
pub static LOGIN: Login = Login {
    id: "qwenapp",
    page: "https://www.qianwen.com/",
    domain: "qianwen.com",
    cookies: &[&["tongyi_sso_ticket"]],
    check,
};

const TOKEN_URL: &str = "https://api.qianwen.com/dialog/asr/getToken";
/// 预取的 token 只在按下快捷键后一分钟内使用，远短于服务端约 10 分钟的有效期
const PREFETCH_TTL: Duration = Duration::from_secs(60);

/// 千问 App 云端识别：登录 Cookie 换临时 token，再走 NLS 风格 WebSocket（JSON 控制帧 + PCM 二进制帧）
#[derive(Default)]
pub struct QwenAppEngine {
    /// 按下快捷键时预取的 token，开始识别时取走：（登录 Cookie，取得时间，token）
    prefetched: Mutex<Option<(String, Instant, Token)>>,
}

struct Token {
    url: String,
    appkey: String,
}

fn check(cookie: &str) -> BoxFuture<'_, Result<()>> {
    Box::pin(async move { fetch(cookie).await.map(drop) })
}

async fn fetch(cookie: &str) -> Result<Token> {
    let v: Value = reqwest::Client::new()
        .post(TOKEN_URL)
        .header("Cookie", cookie)
        .json(&json!({ "source": "tongyi" }))
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .map_err(|e| anyhow!("千问 App 连接失败：{e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("千问 App 响应异常：{e}"))?;
    if v["success"].as_bool() != Some(true) {
        if v["errorCode"] == "NOT_LOGIN" {
            bail!("千问 App 登录已失效，请重新登录");
        }
        bail!("千问 App 换取识别 token 失败：{}", v["errorMsg"].as_str().or(v["errorCode"].as_str()).unwrap_or("未知错误"));
    }
    let d = &v["data"];
    let (Some(domain), Some(appkey), Some(token)) = (d["domain"].as_str(), d["appkey"].as_str(), d["token"].as_str()) else {
        bail!("千问 App 返回的识别 token 缺少字段");
    };
    let ts = match &d["timestamp"] {
        Value::String(s) => s.clone(),
        t => t.to_string(),
    };
    Ok(Token { url: format!("wss://{domain}/ws/v1/recognition?token={token}&appkey={appkey}&timestamp={ts}"), appkey: appkey.into() })
}

fn id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

fn header(event: &str, sid: &str, appkey: &str) -> Value {
    json!({ "reqid": id(), "sessionid": sid, "event": event, "appKey": appkey, "resid": 0 })
}

fn event(v: &Value) -> &str {
    v["header"]["event"].as_str().unwrap_or("")
}

fn failure(v: &Value) -> String {
    let h = &v["header"];
    let msg = h["message"].as_str().or(h["status_message"].as_str()).filter(|s| !s.is_empty()).unwrap_or("识别失败");
    format!("千问 App {msg}")
}

/// 定稿文本：payload.text，缺省时取调试信息里的整句
fn completed(v: &Value) -> String {
    let p = &v["payload"];
    p["text"].as_str().filter(|s| !s.is_empty()).or(p["debug_info_list"][0]["text"].as_str()).unwrap_or("").to_string()
}

async fn open(t: &Token, sid: &str) -> Result<Ws> {
    let mut ws = ws::connect(&t.url, &[]).await.map_err(|e| anyhow!("千问 App {e}"))?;
    let start = json!({
        "header": header("StartRecognition", sid, &t.appkey),
        "payload": { "format": "pcm", "sample_rate": 16000, "enable_intermediate_result": true },
    });
    ws.send(Message::Text(start.to_string())).await?;
    // token 无效时服务端不回错误，直接关闭连接
    let d = ws::recv(&mut ws, Duration::from_secs(5)).await.map_err(|e| anyhow!("千问 App 拒绝了识别请求：{e}"))?;
    let v: Value = serde_json::from_slice(&d)?;
    if event(&v) != "RecognitionStarted" {
        bail!(failure(&v));
    }
    Ok(ws)
}

impl QwenAppEngine {
    async fn token(&self, cookie: &str) -> Result<Token> {
        let prefetched = self.prefetched.lock().await.take();
        match prefetched {
            Some((c, at, token)) if c == cookie && at.elapsed() < PREFETCH_TTL => Ok(token),
            _ => fetch(cookie).await,
        }
    }
}

#[async_trait::async_trait]
impl Engine for QwenAppEngine {
    async fn prewarm(&self) {
        let cookie = LOGIN.get();
        if cookie.is_empty() {
            return;
        }
        // 持锁请求：识别若在请求途中开始，会等这次结果而不是再请求一次
        let mut slot = self.prefetched.lock().await;
        if slot.as_ref().is_some_and(|(c, at, _)| *c == cookie && at.elapsed() < PREFETCH_TTL) {
            return;
        }
        *slot = fetch(&cookie).await.ok().map(|t| (cookie, Instant::now(), t));
    }

    async fn run(&self, audio: Audio, partial: Partial) -> Result<String> {
        let cookie = LOGIN.get();
        if cookie.is_empty() {
            bail!("千问 App 未登录，请在设置的识别渠道里登录");
        }
        let token = self.token(&cookie).await?;
        let sid = id();
        let ws = open(&token, &sid).await?;
        let stop = json!({ "header": header("StopRecognition", &sid, &token.appkey), "payload": {} });
        ws::recognize(ws, audio, stop.to_string(), partial, |v| match event(v) {
            // payload.text 是从开头到当前的整段文本
            "RecognitionResultChanged" => Update::Text(v["payload"]["text"].as_str().unwrap_or("").into()),
            "RecognitionCompleted" => Update::Done(Some(completed(v))),
            "TaskFailed" | "RecognitionFailed" => Update::Error(failure(v)),
            _ => Update::Skip,
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn completed_falls_back_to_debug_info() {
        let v = json!({ "payload": { "debug_info_list": [{ "text": "整句" }] } });
        assert_eq!(completed(&v), "整句");
        let v = json!({ "payload": { "text": "正文", "debug_info_list": [{ "text": "整句" }] } });
        assert_eq!(completed(&v), "正文");
    }
}
