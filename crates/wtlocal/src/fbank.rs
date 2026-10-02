//! HTK 风格 FBank：39 维 log-mel + 对数能量，25ms 窗 / 10ms 帧移；均值按 CMS 先验做在线累计
const WIN: usize = 400;
const HOP: usize = 160;
const NFFT: usize = 512;
const NCH: usize = 39;
pub const DIM: usize = NCH + 1;
/// 在线均值里 CMS 先验均值的权重（帧数）
const PRIOR: f64 = 100.0;

pub struct Cms {
    pub mean: [f64; DIM],
    pub istd: [f64; DIM],
}

impl Cms {
    pub fn parse(b: &[u8]) -> Option<Cms> {
        let f = |i: usize| b.get(4 + i * 4..8 + i * 4).map(|s| f32::from_le_bytes(s.try_into().unwrap()) as f64);
        let mut c = Cms { mean: [0.0; DIM], istd: [0.0; DIM] };
        for i in 0..DIM {
            c.mean[i] = f(i)?;
            c.istd[i] = 1.0 / f(DIM + i)?.max(1e-10).sqrt();
        }
        Some(c)
    }
}

struct Tables {
    ham: Vec<f64>,
    tw: Vec<(f64, f64)>,
    /// 每个频点 k（1..=256）：(低通道, 权重, 高通道, 权重)
    mel: Vec<(usize, f64, usize, f64)>,
}

fn tables() -> &'static Tables {
    static T: std::sync::OnceLock<Tables> = std::sync::OnceLock::new();
    T.get_or_init(|| {
        let pi = std::f64::consts::PI;
        let ham = (0..WIN).map(|n| 0.54 - 0.46 * (2.0 * pi * n as f64 / (WIN - 1) as f64).cos()).collect();
        let tw = (0..NFFT / 2).map(|i| { let a = -2.0 * pi * i as f64 / NFFT as f64; (a.cos(), a.sin()) }).collect();
        let mel = |f: f64| 1127.0 * (1.0 + f / 700.0).ln();
        let hi = mel(8000.0);
        let cf: Vec<f64> = (1..=NCH + 1).map(|i| hi * i as f64 / (NCH + 1) as f64).collect();
        let bins = (1..=NFFT / 2)
            .map(|k| {
                let m = mel(k as f64 * 16000.0 / NFFT as f64);
                let c = cf.iter().take_while(|&&v| v < m).count();
                match c {
                    0 => (0, m / cf[0], 0, 0.0),
                    c if c < NCH => { let w = (cf[c] - m) / (cf[c] - cf[c - 1]); (c - 1, w, c, 1.0 - w) }
                    c if c == NCH => (NCH - 1, (cf[NCH] - m) / (cf[NCH] - cf[NCH - 1]), 0, 0.0),
                    _ => (0, 0.0, 0, 0.0),
                }
            })
            .collect();
        Tables { ham, tw, mel: bins }
    })
}

fn fft(re: &mut [f64; NFFT], im: &mut [f64; NFFT], tw: &[(f64, f64)]) {
    let mut j = 0;
    for i in 1..NFFT {
        let mut b = NFFT >> 1;
        while j & b != 0 {
            j ^= b;
            b >>= 1;
        }
        j |= b;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= NFFT {
        let step = NFFT / len;
        for s in (0..NFFT).step_by(len) {
            for k in 0..len / 2 {
                let (wr, wi) = tw[k * step];
                let (a, b) = (s + k, s + k + len / 2);
                let tr = re[b] * wr - im[b] * wi;
                let ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
        len <<= 1;
    }
}

pub fn frame(x: &[i16]) -> [f64; DIM] {
    let t = tables();
    let mut re = [0.0; NFFT];
    let mut im = [0.0; NFFT];
    let mut e = 0.0;
    for n in 0..WIN {
        let v = x[n] as f64;
        e += v * v;
        let pe = if n == 0 { v * (1.0 - 0.97) } else { v - 0.97 * x[n - 1] as f64 };
        re[n] = pe * t.ham[n];
    }
    fft(&mut re, &mut im, &t.tw);
    let mut out = [0.0; DIM];
    for (k, &(lo, wl, hi, wh)) in t.mel.iter().enumerate() {
        let p = re[k + 1] * re[k + 1] + im[k + 1] * im[k + 1];
        out[lo] += p * wl;
        out[hi] += p * wh;
    }
    for v in &mut out[..NCH] {
        *v = v.max(1.0).ln();
    }
    out[NCH] = e.max(1e-10).ln();
    out
}

/// 流式特征：喂 PCM，产出归一化后的 40 维帧
pub struct Fbank {
    buf: Vec<i16>,
    sum: [f64; DIM],
    n: f64,
}

fn norm(f: &[f64; DIM], sum: &[f64; DIM], n: f64, cms: &Cms) -> [f32; DIM] {
    let mut r = [0f32; DIM];
    for i in 0..DIM {
        let mean = (PRIOR * cms.mean[i] + sum[i]) / (PRIOR + n);
        r[i] = ((f[i] - mean) * cms.istd[i]) as f32;
    }
    r
}

impl Fbank {
    pub fn new() -> Self {
        Fbank { buf: Vec::new(), sum: [0.0; DIM], n: 0.0 }
    }

    pub fn push(&mut self, pcm: &[i16], cms: &Cms, out: &mut Vec<[f32; DIM]>) {
        self.buf.extend_from_slice(pcm);
        let mut p = 0;
        while p + WIN <= self.buf.len() {
            let f = frame(&self.buf[p..p + WIN]);
            self.n += 1.0;
            for i in 0..DIM {
                self.sum[i] += f[i];
            }
            out.push(norm(&f, &self.sum, self.n, cms));
            p += HOP;
        }
        self.buf.drain(..p);
    }

    /// 数字静音帧（按当前均值归一化），用于尾部补齐；归一化空间的全 0 帧并不是静音，会让模型漏字
    pub fn silence(&self, cms: &Cms) -> [f32; DIM] {
        let mut f = [0.0; DIM];
        f[NCH] = 1e-10f64.ln();
        norm(&f, &self.sum, self.n, cms)
    }
}
