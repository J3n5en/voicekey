//! 数值内核：int8 动态量化矩阵乘（aarch64 sdot / x86_64 AVX2 / 标量兜底）与 f32 点积
use rayon::prelude::*;

/// 按行动态量化到 int8（对称，每行一个 scale）
pub struct QAct {
    pub q: Vec<i8>,
    pub s: Vec<f32>,
    pub k: usize,
}

pub fn quant(x: &[f32], k: usize) -> QAct {
    let t = x.len() / k;
    let mut q = vec![0i8; t * k];
    let mut s = vec![0f32; t];
    q.par_chunks_mut(k).zip(s.par_iter_mut()).zip(x.par_chunks(k)).for_each(|((q, s), x)| {
        let m = x.iter().fold(0f32, |a, v| a.max(v.abs()));
        let sc = if m > 0.0 { m / 127.0 } else { 1.0 };
        let inv = 1.0 / sc;
        for (q, v) in q.iter_mut().zip(x) {
            *q = (v * inv).round().clamp(-127.0, 127.0) as i8;
        }
        *s = sc;
    });
    QAct { q, s, k }
}

#[derive(Clone, Copy)]
struct Out(*mut f32);
unsafe impl Send for Out {}
unsafe impl Sync for Out {}

/// out[t×n] = (x · wᵀ) * scale + bias，w 为 [n, k] 行主序 int8
pub fn qgemm(x: &QAct, w: &[i8], n: usize, ws: f32, bias: Option<&[f32]>) -> Vec<f32> {
    let k = x.k;
    let t = x.s.len();
    debug_assert_eq!(w.len(), n * k);
    let mut out = vec![0f32; t * n];
    let o = Out(out.as_mut_ptr());
    const TILE: usize = 32;
    (0..n.div_ceil(TILE)).into_par_iter().for_each(|ti| {
        let o = o;
        let n0 = ti * TILE;
        let n1 = (n0 + TILE).min(n);
        let mut j = n0;
        while j < n1 {
            let rows = (n1 - j).min(4);
            let mut i = 0;
            while i < t {
                let r2 = (t - i).min(2);
                let acc = dot(&x.q[i * k..], r2, &w[j * k..], rows, k);
                for a in 0..r2 {
                    for b in 0..rows {
                        let v = acc[a][b] as f32 * x.s[i + a] * ws + bias.map_or(0.0, |bb| bb[j + b]);
                        unsafe { *o.0.add((i + a) * n + j + b) = v };
                    }
                }
                i += r2;
            }
            j += rows;
        }
    });
    out
}

/// xr 行（≤2）× wr 行（≤4）的 int8 点积；不足的行用重复行指针补齐
#[inline]
fn dot(x: &[i8], xr: usize, w: &[i8], wr: usize, k: usize) -> [[i32; 4]; 2] {
    let xp = [x.as_ptr(), x[(xr - 1) * k..].as_ptr()];
    let wp: [*const i8; 4] = std::array::from_fn(|b| w[b.min(wr - 1) * k..].as_ptr());
    #[cfg(target_arch = "aarch64")]
    if k % 16 == 0 {
        return unsafe { neon::dot2x4(xp, wp, k) };
    }
    #[cfg(target_arch = "x86_64")]
    if k % 32 == 0 && avx2() {
        return unsafe { avx::dot2x4(xp, wp, k) };
    }
    let mut r = [[0i32; 4]; 2];
    for a in 0..xr {
        for b in 0..wr {
            r[a][b] = dot1(&x[a * k..(a + 1) * k], &w[b * k..(b + 1) * k]);
        }
    }
    r
}

fn dot1(a: &[i8], b: &[i8]) -> i32 {
    let mut acc = [0i32; 16];
    let (ca, cb) = (a.chunks_exact(16), b.chunks_exact(16));
    let (ra, rb) = (ca.remainder(), cb.remainder());
    for (x, y) in ca.zip(cb) {
        for i in 0..16 {
            acc[i] += x[i] as i32 * y[i] as i32;
        }
    }
    acc.iter().sum::<i32>() + ra.iter().zip(rb).map(|(&x, &y)| x as i32 * y as i32).sum::<i32>()
}

#[cfg(target_arch = "x86_64")]
fn avx2() -> bool {
    static F: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *F.get_or_init(|| std::is_x86_feature_detected!("avx2"))
}

#[cfg(target_arch = "aarch64")]
mod neon {
    use std::arch::aarch64::*;

    pub unsafe fn dot2x4(x: [*const i8; 2], w: [*const i8; 4], k: usize) -> [[i32; 4]; 2] {
        let mut a = [vdupq_n_s32(0); 8];
        let mut i = 0;
        while i < k {
            let x0 = vld1q_s8(x[0].add(i));
            let x1 = vld1q_s8(x[1].add(i));
            for b in 0..4 {
                let wv = vld1q_s8(w[b].add(i));
                a[b] = vdotq_s32(a[b], x0, wv);
                a[4 + b] = vdotq_s32(a[4 + b], x1, wv);
            }
            i += 16;
        }
        let mut r = [[0; 4]; 2];
        for b in 0..4 {
            r[0][b] = vaddvq_s32(a[b]);
            r[1][b] = vaddvq_s32(a[4 + b]);
        }
        r
    }
}

#[cfg(target_arch = "x86_64")]
mod avx {
    use std::arch::x86_64::*;

    #[target_feature(enable = "avx2")]
    unsafe fn hsum(v: __m256i) -> i32 {
        let s = _mm_add_epi32(_mm256_castsi256_si128(v), _mm256_extracti128_si256(v, 1));
        let s = _mm_add_epi32(s, _mm_shuffle_epi32(s, 0b01_00_11_10));
        let s = _mm_add_epi32(s, _mm_shuffle_epi32(s, 0b10_11_00_01));
        _mm_cvtsi128_si32(s)
    }

    /// |x| (u8) × sign(w, x) (i8) 经 maddubs 成对累加到 i16（|x|≤127 不溢出），再 madd 到 i32
    #[target_feature(enable = "avx2")]
    pub unsafe fn dot2x4(x: [*const i8; 2], w: [*const i8; 4], k: usize) -> [[i32; 4]; 2] {
        let ones = _mm256_set1_epi16(1);
        let mut a = [_mm256_setzero_si256(); 8];
        let mut i = 0;
        while i < k {
            let x0 = _mm256_loadu_si256(x[0].add(i) as *const __m256i);
            let x1 = _mm256_loadu_si256(x[1].add(i) as *const __m256i);
            let (u0, u1) = (_mm256_sign_epi8(x0, x0), _mm256_sign_epi8(x1, x1));
            for b in 0..4 {
                let wv = _mm256_loadu_si256(w[b].add(i) as *const __m256i);
                let p0 = _mm256_madd_epi16(_mm256_maddubs_epi16(u0, _mm256_sign_epi8(wv, x0)), ones);
                let p1 = _mm256_madd_epi16(_mm256_maddubs_epi16(u1, _mm256_sign_epi8(wv, x1)), ones);
                a[b] = _mm256_add_epi32(a[b], p0);
                a[4 + b] = _mm256_add_epi32(a[4 + b], p1);
            }
            i += 32;
        }
        let mut r = [[0; 4]; 2];
        for b in 0..4 {
            r[0][b] = hsum(a[b]);
            r[1][b] = hsum(a[4 + b]);
        }
        r
    }
}

/// f32 点积（8 路累加，便于自动向量化）
#[inline]
pub fn dotf(a: &[f32], b: &[f32]) -> f32 {
    let mut acc = [0f32; 8];
    let (ca, cb) = (a.chunks_exact(8), b.chunks_exact(8));
    let (ra, rb) = (ca.remainder(), cb.remainder());
    for (x, y) in ca.zip(cb) {
        for i in 0..8 {
            acc[i] += x[i] * y[i];
        }
    }
    acc.iter().sum::<f32>() + ra.iter().zip(rb).map(|(x, y)| x * y).sum::<f32>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qgemm_matches_scalar() {
        let (t, k, n) = (5, 64, 11);
        let mut seed = 7u32;
        let mut r = || {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12345);
            (seed >> 16) as i32 % 255 - 127
        };
        let x: Vec<f32> = (0..t * k).map(|_| r() as f32 * 0.01).collect();
        let w: Vec<i8> = (0..n * k).map(|_| r() as i8).collect();
        let b: Vec<f32> = (0..n).map(|i| i as f32).collect();
        let q = quant(&x, k);
        let out = qgemm(&q, &w, n, 0.5, Some(&b));
        for i in 0..t {
            for j in 0..n {
                let e = dot1(&q.q[i * k..(i + 1) * k], &w[j * k..(j + 1) * k]) as f32 * q.s[i] * 0.5 + b[j];
                assert!((out[i * n + j] - e).abs() <= 1e-3 * e.abs().max(1.0), "{i},{j}");
            }
        }
    }
}
