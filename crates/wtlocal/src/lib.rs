//! 微信输入法离线识别：直接加载官方模型包（xnet），纯 Rust 推理，全平台可用
mod fbank;
mod kernels;
mod model;
pub mod pack;
mod stream;
mod xnet;

pub use model::Model;
pub use stream::Stream;

use anyhow::Result;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use voicekey_core::{Audio, Engine, Partial};

/// 中间结果最小间隔（特征帧，10ms/帧）；另外间隔不少于上次计算耗时的 3 倍，慢机器上自动降频
const PARTIAL_EVERY: usize = 30;

static CACHE: Mutex<Option<(PathBuf, Arc<Model>)>> = Mutex::new(None);

pub fn load(dir: &Path) -> Result<Arc<Model>> {
    let mut c = CACHE.lock().unwrap();
    if let Some((d, m)) = c.as_ref() {
        if d == dir {
            return Ok(m.clone());
        }
    }
    let m = Arc::new(Model::load(dir)?);
    *c = Some((dir.to_path_buf(), m.clone()));
    Ok(m)
}

pub struct LocalEngine {
    pub dir: PathBuf,
}

#[async_trait::async_trait]
impl Engine for LocalEngine {
    async fn run(&self, mut audio: Audio, partial: Partial) -> Result<String> {
        let dir = self.dir.clone();
        tokio::task::spawn_blocking(move || {
            let mut s = Stream::new(load(&dir)?);
            let mut last = String::new();
            let (mut done, mut cost) = (Instant::now(), Duration::ZERO);
            while let Some(f) = audio.blocking_recv() {
                s.push(&f);
                while let Ok(f) = audio.try_recv() {
                    s.push(&f);
                }
                if s.fresh() >= PARTIAL_EVERY && done.elapsed() >= cost * 3 {
                    let t0 = Instant::now();
                    let t = s.partial();
                    (done, cost) = (Instant::now(), t0.elapsed());
                    if !t.is_empty() && t != last {
                        partial(&t);
                        last = t;
                    }
                }
            }
            Ok(s.finish())
        })
        .await?
    }

    async fn prewarm(&self) {
        let dir = self.dir.clone();
        let _ = tokio::task::spawn_blocking(move || load(&dir)).await;
    }
}
