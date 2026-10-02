//! HTK 风格 FBank：39 维 log-mel + 对数能量，25ms 窗 / 10ms 帧移；均值、方差以 CMS 为先验按已有音频累计
const WIN: usize = 400;
const HOP: usize = 160;
const NFFT: usize = 512;
const NCH: usize = 39;
pub const DIM: usize = NCH + 1;
/// 在线均值、方差里 CMS 先验的权重（帧数）
const PRIOR: f64 = 100.0;
const VPRIOR: f64 = 50.0;
/// 抖动噪声标准差：给数字静音垫一层底噪，免得方差统计被全零帧拉偏
const DITHER: f64 = 100.0;

pub struct Cms {
    pub mean: [f64; DIM],
    pub var: [f64; DIM],
}

impl Cms {
    pub fn parse(b: &[u8]) -> Option<Cms> {
        let f = |i: usize| b.get(4 + i * 4..8 + i * 4).map(|s| f32::from_le_bytes(s.try_into().unwrap()) as f64);
        let mut c = Cms { mean: [0.0; DIM], var: [0.0; DIM] };
        for i in 0..DIM {
            c.mean[i] = f(i)?;
            c.var[i] = f(DIM + i)?;
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

pub fn frame(x: &[i16], seed: &mut u64) -> [f64; DIM] {
    let t = tables();
    let mut xs = [0.0; WIN];
    for (d, &v) in xs.iter_mut().zip(x) {
        // 4 个均匀分布之和近似高斯，xorshift 保证结果可复现
        let mut g = 0.0;
        for _ in 0..4 {
            *seed ^= *seed << 13;
            *seed ^= *seed >> 7;
            *seed ^= *seed << 17;
            g += (*seed >> 11) as f64 / (1u64 << 53) as f64 - 0.5;
        }
        *d = v as f64 + g * 3f64.sqrt() * DITHER;
    }
    let mut re = [0.0; NFFT];
    let mut im = [0.0; NFFT];
    let mut e = 0.0;
    for n in 0..WIN {
        let v = xs[n];
        e += v * v;
        let pe = if n == 0 { v * (1.0 - 0.97) } else { v - 0.97 * xs[n - 1] };
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

/// 均值、方差归一化参数
pub struct Norm {
    mean: [f64; DIM],
    istd: [f64; DIM],
}

impl Norm {
    pub fn apply(&self, f: &[f64; DIM]) -> [f32; DIM] {
        std::array::from_fn(|i| ((f[i] - self.mean[i]) * self.istd[i]) as f32)
    }
}

/// 数字静音帧，用于窗口末尾补齐；归一化空间的全 0 帧并不是静音，会让模型漏字
pub fn silence() -> [f64; DIM] {
    let mut f = [0.0; DIM];
    f[NCH] = 1e-10f64.ln();
    f
}

/// 流式特征：喂 PCM，产出未归一化的 40 维帧，并累计统计量
pub struct Fbank {
    buf: Vec<i16>,
    sum: [f64; DIM],
    sum2: [f64; DIM],
    n: f64,
    seed: u64,
}

impl Fbank {
    pub fn new() -> Self {
        Fbank { buf: Vec::new(), sum: [0.0; DIM], sum2: [0.0; DIM], n: 0.0, seed: 0x9E37_79B9_7F4A_7C15 }
    }

    /// 按目前为止的音频估计归一化参数。方差也要估计：笔记本麦克风底噪高、动态范围窄，
    /// 固定用 CMS 方差会把特征压扁，模型大量漏字错字
    pub fn norm(&self, cms: &Cms) -> Norm {
        let mut r = Norm { mean: [0.0; DIM], istd: [0.0; DIM] };
        for i in 0..DIM {
            let (m, s, s2) = (cms.mean[i], self.sum[i], self.sum2[i]);
            r.mean[i] = (PRIOR * m + s) / (PRIOR + self.n);
            let mv = (VPRIOR * m + s) / (VPRIOR + self.n);
            let var = (VPRIOR * (cms.var[i] + m * m) + s2) / (VPRIOR + self.n) - mv * mv;
            r.istd[i] = 1.0 / var.max(0.01).sqrt();
        }
        r
    }

    pub fn push(&mut self, pcm: &[i16], out: &mut Vec<[f64; DIM]>) {
        self.buf.extend_from_slice(pcm);
        let mut p = 0;
        while p + WIN <= self.buf.len() {
            let f = frame(&self.buf[p..p + WIN], &mut self.seed);
            self.n += 1.0;
            for i in 0..DIM {
                self.sum[i] += f[i];
                self.sum2[i] += f[i] * f[i];
            }
            out.push(f);
            p += HOP;
        }
        self.buf.drain(..p);
    }
}
