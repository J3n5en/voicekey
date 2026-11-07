use crate::{Audio, Partial};
use anyhow::{anyhow, bail, Result};
use futures_util::{SinkExt, Stream, StreamExt};
use serde_json::Value;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, http::HeaderValue, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

pub type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub async fn connect(url: &str, headers: &[(&str, &str)]) -> Result<Ws> {
    let mut req = url.into_client_request()?;
    for (k, v) in headers {
        req.headers_mut().insert(
            tokio_tungstenite::tungstenite::http::HeaderName::from_bytes(k.as_bytes())?,
            HeaderValue::from_str(v)?,
        );
    }
    let fut = tokio_tungstenite::connect_async(req);
    let (ws, _) = tokio::time::timeout(Duration::from_secs(10), fut)
        .await
        .map_err(|_| anyhow!("连接服务器超时"))?
        .map_err(|e| anyhow!("连接服务器失败：{e}"))?;
    Ok(ws)
}

/// 收下一条数据帧（跳过 ping/pong），超时或关闭报错
pub async fn recv<S, E>(s: &mut S, timeout: Duration) -> Result<Vec<u8>>
where
    S: Stream<Item = Result<Message, E>> + Unpin,
    E: std::fmt::Display,
{
    recv_opt(s, timeout).await?.ok_or_else(|| anyhow!("服务器响应超时"))
}

/// 同 recv，超时返回 None
pub async fn recv_opt<S, E>(s: &mut S, timeout: Duration) -> Result<Option<Vec<u8>>>
where
    S: Stream<Item = Result<Message, E>> + Unpin,
    E: std::fmt::Display,
{
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let Ok(msg) = tokio::time::timeout_at(deadline, s.next()).await else { return Ok(None) };
        if let Some(d) = data(msg)? {
            return Ok(Some(d));
        }
    }
}

/// 数据帧取负载，控制帧返回 None，断开/关闭报错
pub fn data<E: std::fmt::Display>(msg: Option<Result<Message, E>>) -> Result<Option<Vec<u8>>> {
    match msg {
        None => bail!("连接已断开"),
        Some(Err(e)) => bail!("连接异常：{e}"),
        Some(Ok(Message::Binary(b))) => Ok(Some(b.to_vec())),
        Some(Ok(Message::Text(t))) => Ok(Some(t.as_bytes().to_vec())),
        Some(Ok(Message::Close(_))) => bail!("服务器关闭了连接"),
        Some(Ok(_)) => Ok(None),
    }
}

/// 服务端一条 JSON 消息对识别结果的影响
pub enum Update {
    /// 从开头到当前的整段文本
    Text(String),
    /// 识别结束，定稿非空时替换已有文本
    Done(Option<String>),
    Error(String),
    Skip,
}

/// 流式识别收发：音频帧按二进制帧发出，音频结束后发 end，服务端消息交给 parse 解释。
/// 30 秒没有收发即超时，每 15 秒发一次 ping 保活。出错时已识别的文字照常返回
pub async fn recognize(ws: Ws, mut audio: Audio, end: String, partial: Partial, parse: impl Fn(&Value) -> Update + Send + Sync) -> Result<String> {
    const IDLE: Duration = Duration::from_secs(30);
    const PING: Duration = Duration::from_secs(15);
    let (mut tx, mut rx) = ws.split();
    let mut text = String::new();
    let mut sent = false;
    let result: Result<()> = async {
        let mut closed = false;
        let mut idle = Instant::now() + IDLE;
        let mut ping = tokio::time::interval_at(Instant::now() + PING, PING);
        loop {
            tokio::select! {
                biased;
                frame = audio.recv(), if !closed => {
                    idle = Instant::now() + IDLE;
                    match frame {
                        Some(pcm) => {
                            sent = true;
                            tx.send(Message::Binary(pcm.iter().flat_map(|s| s.to_le_bytes()).collect())).await?;
                        }
                        None => {
                            closed = true;
                            tx.send(Message::Text(end.clone())).await?;
                        }
                    }
                }
                msg = rx.next() => {
                    let Some(d) = data(msg)? else { continue };
                    let Ok(v) = serde_json::from_slice::<Value>(&d) else { continue };
                    idle = Instant::now() + IDLE;
                    match parse(&v) {
                        Update::Text(t) => {
                            if !t.is_empty() && t != text {
                                text = t;
                                partial(&text);
                            }
                        }
                        Update::Done(t) => {
                            if let Some(t) = t.filter(|t| !t.is_empty()) {
                                text = t;
                            }
                            return Ok(());
                        }
                        Update::Error(e) => bail!(e),
                        Update::Skip => {}
                    }
                }
                _ = ping.tick() => {
                    let _ = tx.send(Message::Ping(Vec::new())).await;
                }
                _ = tokio::time::sleep_until(idle) => bail!("识别超时"),
            }
        }
    }
    .await;
    let _ = tx.close().await;
    match result {
        Err(e) if text.is_empty() => Err(e),
        _ if text.is_empty() && !sent => bail!("没有采集到音频"),
        _ => Ok(text),
    }
}

/// JoinHandle 被丢弃时终止任务，保证外层 future 取消时不遗留后台任务
pub struct AbortOnDrop<T>(pub tokio::task::JoinHandle<T>);

impl<T> Drop for AbortOnDrop<T> {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl<T> std::future::Future for AbortOnDrop<T> {
    type Output = Result<T, tokio::task::JoinError>;
    fn poll(mut self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<Self::Output> {
        std::pin::Pin::new(&mut self.0).poll(cx)
    }
}
