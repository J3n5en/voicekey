//! 分块流式解码：每块带前文/后文上下文重算，已定稿块不再变化；未定稿尾部只用于中间结果
use crate::fbank::{Fbank, DIM};
use crate::model::Model;
use std::sync::Arc;

/// 前文、块长、后文（特征帧，10ms/帧）；整段一次性解码在长语音上明显变差，分块更稳
const PREV: usize = 200;
const BLK: usize = 400;
const POST: usize = 100;
/// 每个解码窗口末尾补的静音帧：窗口在语音中途截断时，远场/混响音频上模型常整窗不出字，补静音后稳定
const PAD: usize = 50;

pub struct Stream {
    m: Arc<Model>,
    fb: Fbank,
    feats: Vec<[f32; DIM]>,
    ids: Vec<u32>,
    s: usize,
    fresh: usize,
}

impl Stream {
    pub fn new(m: Arc<Model>) -> Self {
        Stream { m, fb: Fbank::new(), feats: Vec::new(), ids: Vec::new(), s: 0, fresh: 0 }
    }

    pub fn push(&mut self, pcm: &[i16]) {
        let n = self.feats.len();
        self.fb.push(pcm, &self.m.cms, &mut self.feats);
        self.fresh += self.feats.len() - n;
        while self.feats.len() >= self.s + BLK + POST {
            self.commit();
        }
    }

    /// 距上次中间结果新增的特征帧数
    pub fn fresh(&self) -> usize {
        self.fresh
    }

    /// 解码 [s - prev, end) 并补 pad 帧静音，返回 s 之后的输出帧
    fn decode(&self, prev: usize, end: usize, pad: usize) -> Vec<u32> {
        let a = self.s.saturating_sub(prev);
        let mut x = self.feats[a..end].to_vec();
        x.resize(x.len() + pad, self.fb.silence(&self.m.cms));
        let out = self.m.forward(&x);
        out.get((self.s - a) / 5..).unwrap_or_default().to_vec()
    }

    fn commit(&mut self) {
        let mut ids = self.decode(PREV, self.s + BLK + POST, PAD);
        ids.truncate(BLK / 5);
        // 在块尾附近的连续 blank 处截断，避免字恰好落在块边界上被两边都丢掉
        if let Some(c) = (ids.len() / 2..ids.len()).rev().find(|&c| ids[c] == 0 && ids[c - 1] == 0) {
            ids.truncate(c);
        }
        self.s += ids.len() * 5;
        self.ids.extend(ids);
    }

    /// 中间结果：已定稿部分 + 尾部临时解码（前文减半以省算力）；去掉末尾标点，避免边说边打时句号反复增删
    pub fn partial(&mut self) -> String {
        self.fresh = 0;
        let mut ids = self.ids.clone();
        if self.feats.len() > self.s {
            ids.extend(self.decode(PREV / 2, self.feats.len(), PAD));
        }
        tidy(&self.m.text(&ids)).trim_end_matches(PUNCT).to_string()
    }

    pub fn finish(mut self) -> String {
        if self.feats.len() > self.s {
            let tail = self.decode(PREV, self.feats.len(), POST);
            self.ids.extend(tail);
        }
        tidy(&self.m.text(&self.ids)).to_string()
    }
}

const PUNCT: &[char] = &['，', '。', '？', '！', '、', ',', '.', '?', '!'];

/// 开口前的底噪偶尔被识别成一个逗号
fn tidy(t: &str) -> &str {
    t.trim_start_matches(PUNCT)
}
