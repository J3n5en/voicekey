//! 官方 .xnet 模型文件：只读算子（权重/常量）记录表位于文件尾部，按名称索引
use anyhow::{bail, Context, Result};
use std::collections::HashMap;

pub const F32: u32 = 11;
pub const I8: u32 = 6;

pub struct Rec {
    pub dtype: u32,
    pub scale: Option<f32>,
    pub dims: Vec<usize>,
    pub off: usize,
    pub len: usize,
}

struct Cur<'a> {
    d: &'a [u8],
    p: usize,
}

impl Cur<'_> {
    fn u32(&mut self) -> Option<u32> {
        let b = self.d.get(self.p..self.p + 4)?;
        self.p += 4;
        Some(u32::from_le_bytes(b.try_into().unwrap()))
    }
    fn take(&mut self, n: usize) -> Option<&[u8]> {
        let b = self.d.get(self.p..self.p.checked_add(n)?)?;
        self.p += n;
        Some(b)
    }
}

fn elem(dtype: u32) -> Option<usize> {
    match dtype {
        I8 | 2 | 3 => Some(1),
        4 | 5 => Some(2),
        1 | 7 | 8 | F32 => Some(4),
        9 | 10 | 12 => Some(8),
        _ => None,
    }
}

/// 从 p 起逐条解析，必须恰好解析到文件尾（零长度名 + 全零填充）
fn chain(d: &[u8], p: usize) -> Option<HashMap<String, Rec>> {
    let mut c = Cur { d, p };
    let mut out = HashMap::new();
    loop {
        let n = c.u32()? as usize;
        if n == 0 {
            let rest = &d[c.p..];
            return (rest.len() <= 16 && rest.iter().all(|&b| b == 0) && out.len() > 100).then_some(out);
        }
        if n > 256 {
            return None;
        }
        let name = std::str::from_utf8(c.take(n)?).ok()?.to_string();
        let dtype = c.u32()?;
        let es = elem(dtype)?;
        let quant = c.u32()?;
        for _ in 0..3 {
            c.u32()?;
        }
        let ns = c.u32()? as usize;
        c.u32()?;
        if ns > 4096 {
            return None;
        }
        let sc = c.take(ns * 4)?;
        let scale = (quant != 0 && ns > 0).then(|| f32::from_le_bytes(sc[..4].try_into().unwrap()));
        let nz = c.u32()? as usize;
        c.take(nz)?;
        let nd = c.u32()? as usize;
        if nd > 8 {
            return None;
        }
        let dims = (0..nd).map(|_| c.u32().map(|v| v as usize)).collect::<Option<Vec<_>>>()?;
        let len = c.u32()? as usize;
        if len != dims.iter().product::<usize>() * es {
            return None;
        }
        let off = c.p;
        c.take(len)?;
        out.insert(name, Rec { dtype, scale, dims, off, len });
    }
}

pub fn parse(d: &[u8]) -> Result<HashMap<String, Rec>> {
    if d.get(..4) != Some(b"XNET") {
        bail!("不是 xnet 模型文件");
    }
    // 只读记录表的首条名称以 "/" 或字母开头，前缀为 u32 长度；逐个候选尝试完整解析
    let mut p = 8;
    while let Some(i) = d[p..].windows(4).position(|w| w[1..] == [0, 0, 0] && (1..=128).contains(&w[0])) {
        let at = p + i;
        let n = d[at] as usize;
        if let Some(name) = d.get(at + 4..at + 4 + n) {
            if name.iter().all(|b| b.is_ascii_graphic()) {
                if let Some(m) = chain(d, at) {
                    return Ok(m);
                }
            }
        }
        p = at + 1;
    }
    None.context("找不到 xnet 权重表")
}
