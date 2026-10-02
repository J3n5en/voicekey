//! 声学模型：卷积前端 + 40 层 pre-norm Transformer + CTC 输出层；int8 权重直接 mmap 自 xnet
use crate::fbank::DIM;
use crate::kernels::{dotf, qgemm, quant, QAct};
use crate::xnet::{self, Rec, F32, I8};
use anyhow::{bail, Context, Result};
use memmap2::Mmap;
use rayon::prelude::*;
use std::collections::HashMap;
use std::path::Path;

const D: usize = 512;
const HEADS: usize = 8;
const HD: usize = D / HEADS;
const FF: usize = 2048;
const LAYERS: usize = 40;
const F1: usize = 32; // 卷积通道
const F2: usize = 64;
const F3: usize = 192;
const K2: usize = F1 * 49;
const K3: usize = F2 * 9;
const W2: usize = DIM + 1; // 第二层卷积后频率维补一列 0
const FLAT: usize = F3 * 20;

struct Q {
    off: usize,
    n: usize,
    k: usize,
    s: f32,
}

struct Layer {
    pn: (Vec<f32>, Vec<f32>),
    mn: (Vec<f32>, Vec<f32>),
    q: Q,
    k: Q,
    v: Q,
    o: Q,
    f1: Q,
    f1b: Vec<f32>,
    f2: Q,
    f2b: Vec<f32>,
}

pub struct Model {
    map: Mmap,
    c1: Vec<f32>,
    c2: Vec<f32>,
    c3: Vec<f32>,
    lin: Q,
    lin_b: Vec<f32>,
    layers: Vec<Layer>,
    out: Q,
    out_b: Vec<f32>,
    vocab: Vec<String>,
}

struct Loader<'a> {
    d: &'a [u8],
    r: HashMap<String, Rec>,
}

impl Loader<'_> {
    fn rec(&self, name: &str) -> Result<&Rec> {
        self.r.get(name).with_context(|| format!("模型缺少 {name}"))
    }
    fn f32(&self, name: &str, dims: &[usize]) -> Result<Vec<f32>> {
        let r = self.rec(name)?;
        if r.dtype != F32 || r.dims != dims {
            bail!("{name} 形状不符：{:?}", r.dims);
        }
        Ok(self.d[r.off..r.off + r.len].chunks_exact(4).map(|b| f32::from_le_bytes(b.try_into().unwrap())).collect())
    }
    fn q(&self, name: &str, n: usize, k: usize) -> Result<Q> {
        let name = format!("{name}.weight_quantized_s8");
        let r = self.rec(&name)?;
        if r.dtype != I8 || r.dims.len() < 2 || r.dims[..2] != [n, k] || r.len != n * k {
            bail!("{name} 形状不符：{:?}", r.dims);
        }
        Ok(Q { off: r.off, n, k, s: r.scale.context("缺少量化参数")? })
    }
    fn norm(&self, name: &str) -> Result<(Vec<f32>, Vec<f32>)> {
        Ok((self.f32(&format!("{name}.weight"), &[D])?, self.f32(&format!("{name}.bias"), &[D])?))
    }
}

impl Model {
    pub fn load(dir: &Path) -> Result<Model> {
        let xnet = std::fs::read_dir(dir)
            .map_err(|_| anyhow::anyhow!("离线模型未下载"))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .find(|p| p.extension().is_some_and(|e| e == "xnet"))
            .context("模型文件不存在")?;
        let map = unsafe { Mmap::map(&std::fs::File::open(&xnet)?)? };
        #[cfg(unix)]
        let _ = map.advise(memmap2::Advice::WillNeed);
        let l = Loader { d: &map, r: xnet::parse(&map)? };
        let mut layers = Vec::with_capacity(LAYERS);
        for i in 0..LAYERS {
            let p = |s: &str| format!("layers.{i}.{s}");
            layers.push(Layer {
                pn: l.norm(&p("prior_norm"))?,
                mn: l.norm(&p("middle_norm"))?,
                q: l.q(&p("attention.q_conv"), D, D)?,
                k: l.q(&p("attention.k_conv"), D, D)?,
                v: l.q(&p("attention.v_conv"), D, D)?,
                o: l.q(&p("attention.output_transform_conv"), D, D)?,
                f1: l.q(&p("feed_forward.filter_conv"), FF, D)?,
                f1b: l.f32(&p("feed_forward.filter_conv.bias"), &[FF])?,
                f2: l.q(&p("feed_forward.output_conv"), D, FF)?,
                f2b: l.f32(&p("feed_forward.output_conv.bias"), &[D])?,
            });
        }
        let out = l.rec("output_conv.bias")?.dims.first().copied().unwrap_or(0);
        let vocab: Vec<String> = std::fs::read_to_string(dir.join("dict.decoder.utf8.txt"))
            .context("词表不存在")?
            .lines()
            .map(|s| s.split(' ').nth(1).unwrap_or("").to_string())
            .collect();
        if vocab.len() != out {
            bail!("词表大小 {} 与模型输出 {out} 不符", vocab.len());
        }
        Ok(Model {
            c1: l.f32("frontend.conv2d.weight", &[F1, 1, 5, 5])?,
            c2: l.f32("frontend.conv2d_1.weight", &[F2, F1, 7, 7])?,
            c3: l.f32("frontend.conv2d_2.weight", &[F3, F2, 3, 3])?,
            lin: l.q("frontend.linear", D, FLAT)?,
            lin_b: l.f32("frontend.linear.bias", &[D])?,
            layers,
            out: l.q("output_conv", out, D)?,
            out_b: l.f32("output_conv.bias", &[out])?,
            vocab,
            map,
        })
    }

    fn mm(&self, x: &QAct, q: &Q, b: Option<&[f32]>) -> Vec<f32> {
        let w = &self.map[q.off..q.off + q.n * q.k];
        let w = unsafe { std::slice::from_raw_parts(w.as_ptr() as *const i8, w.len()) };
        qgemm(x, w, q.n, q.s, b)
    }

    /// 输入归一化特征帧，输出每个 50ms 输出帧的 argmax token id
    pub fn forward(&self, x: &[[f32; DIM]]) -> Vec<u32> {
        // 独立小线程池：4 线程以上收益很小，却会明显增加调度开销与整机占用
        static POOL: std::sync::LazyLock<rayon::ThreadPool> = std::sync::LazyLock::new(|| {
            let n = std::thread::available_parallelism().map_or(2, |n| n.get()).min(4);
            rayon::ThreadPoolBuilder::new().num_threads(n).thread_name(|i| format!("wtlocal-{i}")).build().unwrap()
        });
        POOL.install(|| self.run(x))
    }

    fn run(&self, x: &[[f32; DIM]]) -> Vec<u32> {
        let t = x.len();
        if t < 5 {
            return Vec::new();
        }
        let t1 = (t - 5) / 5 + 1;
        let at = |i: usize, d: isize| -> Option<usize> { i.checked_add_signed(d) };

        // conv 5×5, 1→32, 时频各补 2
        let mut y1 = vec![0f32; t * F1 * DIM];
        y1.par_chunks_mut(F1 * DIM).enumerate().for_each(|(ti, y)| {
            let mut p = [[0f32; 25]; DIM];
            for (f, pf) in p.iter_mut().enumerate() {
                for i in 0..5 {
                    let Some(tt) = at(ti, i as isize - 2).filter(|&v| v < t) else { continue };
                    for j in 0..5 {
                        if let Some(ff) = at(f, j as isize - 2).filter(|&v| v < DIM) {
                            pf[i * 5 + j] = x[tt][ff];
                        }
                    }
                }
            }
            for o in 0..F1 {
                let w = &self.c1[o * 25..o * 25 + 25];
                for f in 0..DIM {
                    y[o * DIM + f] = dotf(w, &p[f]).max(0.0);
                }
            }
        });

        // conv 7×7, 32→64, 时间步长 5（时补 1、频补 3）
        let mut y2 = vec![0f32; t1 * F2 * W2];
        y2.par_chunks_mut(F2 * W2).enumerate().for_each(|(ti, y)| {
            let mut p = vec![0f32; DIM * K2];
            for i in 0..7 {
                let Some(tt) = at(ti * 5 + i, -1).filter(|&v| v < t) else { continue };
                let row = &y1[tt * F1 * DIM..(tt + 1) * F1 * DIM];
                for c in 0..F1 {
                    for f in 0..DIM {
                        for j in 0..7 {
                            if let Some(ff) = at(f + j, -3).filter(|&v| v < DIM) {
                                p[f * K2 + c * 49 + i * 7 + j] = row[c * DIM + ff];
                            }
                        }
                    }
                }
            }
            for o in 0..F2 {
                let w = &self.c2[o * K2..(o + 1) * K2];
                for f in 0..DIM {
                    y[o * W2 + f] = dotf(w, &p[f * K2..(f + 1) * K2]).max(0.0);
                }
            }
        });

        // conv 3×3, 64→192, 频率步长 2（时补 1）→ [t1][192×20]
        let mut y3 = vec![0f32; t1 * FLAT];
        y3.par_chunks_mut(FLAT).enumerate().for_each(|(ti, y)| {
            let mut p = vec![0f32; 20 * K3];
            for i in 0..3 {
                let Some(tt) = at(ti + i, -1).filter(|&v| v < t1) else { continue };
                let row = &y2[tt * F2 * W2..(tt + 1) * F2 * W2];
                for c in 0..F2 {
                    for f in 0..20 {
                        for j in 0..3 {
                            p[f * K3 + c * 9 + i * 3 + j] = row[c * W2 + 2 * f + j];
                        }
                    }
                }
            }
            for o in 0..F3 {
                let w = &self.c3[o * K3..(o + 1) * K3];
                for f in 0..20 {
                    y[o * 20 + f] = dotf(w, &p[f * K3..(f + 1) * K3]).max(0.0);
                }
            }
        });

        let mut h = self.mm(&quant(&y3, FLAT), &self.lin, Some(&self.lin_b));
        for l in &self.layers {
            let y = quant(&norm(&h, &l.pn), D);
            let (q, k, v) = (self.mm(&y, &l.q, None), self.mm(&y, &l.k, None), self.mm(&y, &l.v, None));
            add(&mut h, &self.mm(&quant(&attention(&q, &k, &v, t1), D), &l.o, None));
            let mut f = self.mm(&quant(&norm(&h, &l.mn), D), &l.f1, Some(&l.f1b));
            f.par_iter_mut().for_each(|v| *v = gelu(*v));
            add(&mut h, &self.mm(&quant(&f, FF), &l.f2, Some(&l.f2b)));
        }
        let lo = self.mm(&quant(&h, D), &self.out, Some(&self.out_b));
        lo.par_chunks(self.out.n)
            .map(|r| r.iter().enumerate().fold((0, f32::MIN), |b, (i, &v)| if v > b.1 { (i, v) } else { b }).0 as u32)
            .collect()
    }

    /// CTC 折叠：去重、去 blank；英文词首（|xxx）前补空格
    pub fn text(&self, ids: &[u32]) -> String {
        let mut s = String::new();
        let mut prev = u32::MAX;
        for &i in ids {
            if i != prev && i != 0 {
                match self.vocab[i as usize].as_str() {
                    "<UNK>" => {}
                    "<SPACE>" => s.push(' '),
                    t if t.len() > 1 && t.starts_with('|') => {
                        if s.ends_with(|c: char| c.is_ascii_alphanumeric()) {
                            s.push(' ');
                        }
                        s.push_str(&t[1..]);
                    }
                    t => s.push_str(t),
                }
            }
            prev = i;
        }
        s
    }
}

fn norm(x: &[f32], (g, b): &(Vec<f32>, Vec<f32>)) -> Vec<f32> {
    let mut y = x.to_vec();
    y.par_chunks_mut(D).for_each(|r| {
        let m = r.iter().sum::<f32>() / D as f32;
        let v = r.iter().map(|x| (x - m) * (x - m)).sum::<f32>() / D as f32;
        let inv = 1.0 / (v + 1e-6).sqrt();
        for i in 0..D {
            r[i] = (r[i] - m) * inv * g[i] + b[i];
        }
    });
    y
}

fn add(h: &mut [f32], o: &[f32]) {
    h.iter_mut().zip(o).for_each(|(a, b)| *a += b);
}

fn gelu(x: f32) -> f32 {
    0.5 * x * (1.0 + (0.797_884_6 * (x + 0.044715 * x * x * x)).tanh())
}

fn attention(q: &[f32], k: &[f32], v: &[f32], t: usize) -> Vec<f32> {
    let mut out = vec![0f32; t * D];
    out.par_chunks_mut(D).enumerate().for_each(|(i, o)| {
        let mut s = vec![0f32; t];
        for h in 0..HEADS {
            let qi = &q[i * D + h * HD..i * D + (h + 1) * HD];
            for (j, sj) in s.iter_mut().enumerate() {
                *sj = dotf(qi, &k[j * D + h * HD..j * D + (h + 1) * HD]) * 0.125;
            }
            let m = s.iter().fold(f32::MIN, |a, &b| a.max(b));
            let mut z = 0.0;
            for sj in s.iter_mut() {
                *sj = (*sj - m).exp();
                z += *sj;
            }
            let oh = &mut o[h * HD..(h + 1) * HD];
            for (j, &a) in s.iter().enumerate() {
                let vj = &v[j * D + h * HD..j * D + (h + 1) * HD];
                for d in 0..HD {
                    oh[d] += a / z * vj[d];
                }
            }
        }
    });
    out
}
