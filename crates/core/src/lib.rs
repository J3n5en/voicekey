pub mod audio;
pub mod doubao;
pub mod opus;
pub mod pb;
pub mod qwen;
pub mod util;
pub mod wetype;
pub mod ws;

use anyhow::Result;
use tokio::sync::mpsc;

/// 16kHz/mono/Int16 的 20ms（320 样本）帧流，发送端关闭即松手
pub type Audio = mpsc::UnboundedReceiver<Vec<i16>>;
pub type Partial = Box<dyn Fn(&str) + Send + Sync>;

#[async_trait::async_trait]
pub trait Engine: Send + Sync {
    /// 消费音频帧，中间结果经 partial 回调，返回最终文本
    async fn run(&self, audio: Audio, partial: Partial) -> Result<String>;
    /// 预先建连，缩短首包延迟
    async fn prewarm(&self) {}
}

pub use doubao::DoubaoEngine;
pub use qwen::{QwenEngine, QwenOutput};
pub use wetype::WeTypeEngine;
