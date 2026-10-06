use crate::Audio;
use anyhow::{anyhow, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rubato::{FftFixedIn, Resampler};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

#[cfg(target_os = "macos")]
mod devices;
#[cfg(target_os = "macos")]
pub use devices::watch_microphones;

pub const FRAME: usize = 320;

/// 任意采样率的单声道 f32 → 16kHz Int16，按 20ms 切帧
pub struct Framer {
    rs: Option<FftFixedIn<f32>>,
    inbuf: Vec<f32>,
    pending: Vec<i16>,
}

impl Framer {
    pub fn new(rate: u32) -> Result<Self> {
        let rs = if rate == 16000 {
            None
        } else {
            Some(FftFixedIn::new(rate as usize, 16000, (rate / 100) as usize, 1, 1)?)
        };
        Ok(Self { rs, inbuf: Vec::new(), pending: Vec::new() })
    }

    pub fn push(&mut self, mono: &[f32]) -> Vec<Vec<i16>> {
        match &mut self.rs {
            None => self.pending.extend(mono.iter().map(|&s| to_i16(s))),
            Some(rs) => {
                self.inbuf.extend_from_slice(mono);
                loop {
                    let need = rs.input_frames_next();
                    if self.inbuf.len() < need {
                        break;
                    }
                    if let Ok(out) = rs.process(&[&self.inbuf[..need]], None) {
                        self.pending.extend(out[0].iter().map(|&s| to_i16(s)));
                    }
                    self.inbuf.drain(..need);
                }
            }
        }
        let mut frames = Vec::new();
        while self.pending.len() >= FRAME {
            frames.push(self.pending.drain(..FRAME).collect());
        }
        frames
    }

    /// 不足一帧的尾巴补零
    pub fn flush(&mut self) -> Option<Vec<i16>> {
        if self.pending.is_empty() {
            return None;
        }
        let mut f = std::mem::take(&mut self.pending);
        f.resize(FRAME, 0);
        Some(f)
    }
}

fn to_i16(s: f32) -> i16 {
    (s.clamp(-1.0, 1.0) * 32767.0) as i16
}

/// RMS → dBFS，-50dB 以下视为静音，-10dB 封顶，归一到 0...1
pub fn level(frame: &[i16]) -> f32 {
    let sum: f32 = frame.iter().map(|&s| (s as f32) * (s as f32)).sum();
    let rms = (sum / frame.len() as f32).sqrt() / 32768.0;
    let db = 20.0 * rms.max(1e-6).log10();
    ((db + 50.0) / 40.0).clamp(0.0, 1.0)
}

pub fn microphones() -> Vec<String> {
    #[cfg(target_os = "macos")]
    return devices::microphones();

    #[cfg(not(target_os = "macos"))]
    cpal::default_host()
        .input_devices()
        .map(|it| it.filter_map(|d| d.name().ok()).collect())
        .unwrap_or_default()
}

#[cfg(target_os = "macos")]
fn named_input<D>(devices: impl Iterator<Item = D>, name: &str, device_name: impl Fn(&D) -> Option<String>, has_input: impl Fn(&D) -> bool) -> Option<D> {
    devices.filter(|d| device_name(d).as_deref() == Some(name)).find(has_input)
}

fn selected_device(host: &cpal::Host, name: &str) -> Option<cpal::Device> {
    #[cfg(target_os = "macos")]
    {
        // cpal 检查输入配置会建 AudioUnit，先匹配名称，避免触碰其他蓝牙设备。
        named_input(host.devices().ok()?, name, |d| d.name().ok(), |d| {
            d.supported_input_configs().map(|mut configs| configs.any(|c| c.channels() > 0)).unwrap_or(false)
        })
    }
    #[cfg(not(target_os = "macos"))]
    host.input_devices().ok()?.find(|d| d.name().ok().as_deref() == Some(name))
}

#[cfg(not(target_os = "macos"))]
pub fn watch_microphones(on_change: impl Fn(Vec<String>) + Send + 'static) {
    std::thread::spawn(move || {
        let mut previous = None;
        loop {
            let current = (microphones(), cpal::default_host().default_input_device().and_then(|d| d.name().ok()));
            if previous.as_ref() != Some(&current) {
                on_change(current.0.clone());
                previous = Some(current);
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    });
}

type LevelFn = Box<dyn Fn(f32) + Send>;

struct Shared {
    framer: Framer,
    tx: Option<mpsc::UnboundedSender<Vec<i16>>>,
    on_level: LevelFn,
}

impl Shared {
    fn feed(&mut self, mono: &[f32]) {
        for f in self.framer.push(mono) {
            (self.on_level)(level(&f));
            if let Some(tx) = &self.tx {
                let _ = tx.send(f);
            }
        }
    }
}

/// 麦克风采集；cpal Stream 不能跨线程，放在专用线程里持有
pub struct Recorder {
    stop: Option<std::sync::mpsc::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
    shared: Arc<Mutex<Shared>>,
}

impl Recorder {
    /// mic 为设备名，找不到时回落系统默认
    pub fn start(mic: Option<&str>, on_level: impl Fn(f32) + Send + 'static) -> Result<(Self, Audio)> {
        let host = cpal::default_host();
        let device = mic
            .filter(|m| !m.is_empty())
            // 同名蓝牙输出/输入可能是不同 ID；实际采集仍只匹配已就绪的输入设备。
            .and_then(|m| selected_device(&host, m))
            .or_else(|| host.default_input_device())
            .ok_or_else(|| anyhow!("没有可用的麦克风"))?;
        let config = device.default_input_config().map_err(|e| anyhow!("麦克风打开失败：{e}"))?;
        if config.channels() == 0 {
            return Err(anyhow!("麦克风输入通道尚未就绪"));
        }
        let (tx, rx) = mpsc::unbounded_channel();
        let shared = Arc::new(Mutex::new(Shared {
            framer: Framer::new(config.sample_rate().0)?,
            tx: Some(tx),
            on_level: Box::new(on_level),
        }));
        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<()>>();
        let sh = shared.clone();
        let thread = std::thread::spawn(move || {
            let channels = config.channels() as usize;
            let stream_cfg: cpal::StreamConfig = config.clone().into();
            let err_fn = |e| eprintln!("audio stream error: {e}");
            macro_rules! build {
                ($t:ty, $conv:expr) => {{
                    let sh = sh.clone();
                    device.build_input_stream(
                        &stream_cfg,
                        move |data: &[$t], _: &_| {
                            let mono: Vec<f32> = data
                                .chunks(channels)
                                .map(|c| c.iter().map(|&s| $conv(s)).sum::<f32>() / channels as f32)
                                .collect();
                            sh.lock().unwrap().feed(&mono);
                        },
                        err_fn,
                        None,
                    )
                }};
            }
            let stream = match config.sample_format() {
                cpal::SampleFormat::F32 => build!(f32, |s: f32| s),
                cpal::SampleFormat::I16 => build!(i16, |s: i16| s as f32 / 32768.0),
                cpal::SampleFormat::I32 => build!(i32, |s: i32| s as f32 / 2147483648.0),
                cpal::SampleFormat::U16 => build!(u16, |s: u16| (s as f32 - 32768.0) / 32768.0),
                f => {
                    let _ = ready_tx.send(Err(anyhow!("不支持的音频格式 {f:?}")));
                    return;
                }
            };
            let stream = match stream.map_err(|e| anyhow!("麦克风打开失败：{e}")).and_then(|s| {
                s.play().map_err(|e| anyhow!("麦克风启动失败：{e}"))?;
                Ok(s)
            }) {
                Ok(s) => s,
                Err(e) => {
                    let _ = ready_tx.send(Err(e));
                    return;
                }
            };
            let _ = ready_tx.send(Ok(()));
            let _ = stop_rx.recv();
            drop(stream);
        });
        ready_rx.recv().map_err(|_| anyhow!("麦克风线程异常退出"))??;
        Ok((Self { stop: Some(stop_tx), thread: Some(thread), shared }, rx))
    }

    /// 停止采集，补齐尾帧并关闭帧流
    pub fn stop(&mut self) {
        if let Some(s) = self.stop.take() {
            let _ = s.send(());
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
        let mut sh = self.shared.lock().unwrap();
        if let Some(f) = sh.framer.flush() {
            if let Some(tx) = &sh.tx {
                let _ = tx.send(f);
            }
        }
        sh.tx = None;
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(all(test, target_os = "macos"))]
mod selection_tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn name_is_matched_before_input_probe_and_same_name_output_is_skipped() {
        let devices = [("Other headset", 1), ("Selected headset", 0), ("Selected headset", 1)];
        let probed = RefCell::new(Vec::new());
        let selected = named_input(devices.into_iter(), "Selected headset", |d| Some(d.0.into()), |d| {
            probed.borrow_mut().push(*d);
            d.1 > 0
        });
        assert_eq!(selected, Some(("Selected headset", 1)));
        assert_eq!(*probed.borrow(), devices[1..]);
    }

    #[test]
    fn missing_or_zero_channel_input_falls_back_to_default() {
        for devices in [vec![], vec![("Selected headset", 0)], vec![("Other headset", 1)]] {
            let selected = named_input(devices.into_iter(), "Selected headset", |d| Some(d.0.into()), |d| d.1 > 0);
            assert_eq!(selected.or(Some(("Default", 1))), Some(("Default", 1)));
        }
    }
}

/// 调试用：读 wav 文件，按实时节奏喂帧
pub fn file_frames(path: &str, realtime: bool) -> Result<Audio> {
    let mut r = hound::WavReader::open(path)?;
    let spec = r.spec();
    let ch = spec.channels as usize;
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Int => {
            let scale = (1i64 << (spec.bits_per_sample - 1)) as f32;
            r.samples::<i32>().map(|s| s.map(|v| v as f32 / scale)).collect::<Result<_, _>>()?
        }
        hound::SampleFormat::Float => r.samples::<f32>().collect::<Result<_, _>>()?,
    };
    let mono: Vec<f32> = samples.chunks(ch).map(|c| c.iter().sum::<f32>() / ch as f32).collect();
    let mut framer = Framer::new(spec.sample_rate)?;
    let mut frames = framer.push(&mono);
    frames.extend(framer.flush());
    let (tx, rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        for f in frames {
            if tx.send(f).is_err() {
                break;
            }
            if realtime {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        }
    });
    Ok(rx)
}
