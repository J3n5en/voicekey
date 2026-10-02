//! 分块流式解码：每块带前文/后文上下文重算；说话中按已有音频的统计量归一化出中间结果，
//! 结束时按整段统计量重算一遍出定稿（录音越短统计越不准，整段重算错字率约降一半）
use crate::fbank::{silence, Fbank, Norm, DIM};
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
    feats: Vec<[f64; DIM]>,
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
        self.fb.push(pcm, &mut self.feats);
        self.fresh += self.feats.len() - n;
        if self.feats.len() >= self.s + BLK + POST {
            let nm = self.fb.norm(&self.m.cms);
            while self.feats.len() >= self.s + BLK + POST {
                let ids = self.block(self.s, &nm);
                self.s += ids.len() * 5;
                self.ids.extend(ids);
            }
        }
    }

    /// 距上次中间结果新增的特征帧数
    pub fn fresh(&self) -> usize {
        self.fresh
    }

    /// 解码 [s - prev, end) 并补 pad 帧静音，返回 s 之后的输出帧
    fn decode(&self, s: usize, prev: usize, end: usize, pad: usize, nm: &Norm) -> Vec<u32> {
        let a = s.saturating_sub(prev);
        let mut x: Vec<[f32; DIM]> = self.feats[a..end].iter().map(|f| nm.apply(f)).collect();
        x.resize(x.len() + pad, nm.apply(&silence()));
        let out = self.m.forward(&x);
        out.get((s - a) / 5..).unwrap_or_default().to_vec()
    }

    /// 从 s 起定稿一块
    fn block(&self, s: usize, nm: &Norm) -> Vec<u32> {
        let mut ids = self.decode(s, PREV, s + BLK + POST, PAD, nm);
        ids.truncate(BLK / 5);
        // 在块尾附近的连续 blank 处截断，避免字恰好落在块边界上被两边都丢掉
        if let Some(c) = (ids.len() / 2..ids.len()).rev().find(|&c| ids[c] == 0 && ids[c - 1] == 0) {
            ids.truncate(c);
        }
        ids
    }

    /// 中间结果：已定稿部分 + 尾部临时解码（前文减半以省算力）；去掉末尾标点，避免边说边打时句号反复增删
    pub fn partial(&mut self) -> String {
        self.fresh = 0;
        let mut ids = self.ids.clone();
        if self.feats.len() > self.s {
            ids.extend(self.decode(self.s, PREV / 2, self.feats.len(), PAD, &self.fb.norm(&self.m.cms)));
        }
        tidy(&self.m.text(&ids)).trim_end_matches(PUNCT).to_string()
    }

    pub fn finish(self) -> String {
        let nm = self.fb.norm(&self.m.cms);
        let (mut s, mut ids) = (0, Vec::new());
        while self.feats.len() >= s + BLK + POST {
            let b = self.block(s, &nm);
            s += b.len() * 5;
            ids.extend(b);
        }
        if self.feats.len() > s {
            ids.extend(self.decode(s, PREV, self.feats.len(), POST, &nm));
        }
        tidy(&self.m.text(&ids))
    }
}

const PUNCT: &[char] = &['，', '。', '？', '！', '、', ',', '.', '?', '!'];

/// 开口前的底噪偶尔被识别成一个逗号；块边界偶尔出现「，。」这样的连续标点，只留后一个
fn tidy(t: &str) -> String {
    let c: Vec<char> = t.trim_start_matches(PUNCT).chars().collect();
    c.iter().enumerate().filter(|&(i, ch)| !(PUNCT.contains(ch) && c.get(i + 1).is_some_and(|n| PUNCT.contains(n)))).map(|(_, ch)| ch).collect()
}
