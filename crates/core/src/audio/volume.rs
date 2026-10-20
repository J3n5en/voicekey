//! macOS 录音时调整系统输出音量：开始录音时压低，结束后还原
//!
//! 音量以 0.0–1.0 标量表示，通过 CoreAudio 的 `kAudioDevicePropertyVolumeScalar`
//! 读写。部分设备只在 main element（element 0）提供音量，另一些（如内置扬声器）
//! 只在左右声道 element 1/2 提供，因此读写时同时尝试两种形态。

use anyhow::{anyhow, Result};
use coreaudio_sys::*;
use std::ffi::c_void;
use std::mem::size_of;
use std::ptr::null;
use std::sync::{Arc, Mutex};

const VOLUME_SELECTOR: AudioObjectPropertySelector = kAudioDevicePropertyVolumeScalar;

/// 一次「压低」保存下来的原始状态：设备、各 element 的原音量
#[derive(Clone, Copy, Debug, PartialEq)]
struct Saved {
    device: AudioObjectID,
    /// 0 表示 main element，1/2 表示左右声道
    elements: [u32; 2],
    volumes: [f32; 2],
    len: usize,
}

/// 读写系统音量的底层能力；与状态机分离，便于测试
pub trait VolumeAdapter: Send + Sync {
    /// 默认输出设备；取不到时返回 None
    fn output_device(&self) -> Option<AudioObjectID>;
    /// 该设备上可写的音量 element（main 优先，否则左右声道）
    fn writable_elements(&self, device: AudioObjectID) -> Vec<u32>;
    fn read(&self, device: AudioObjectID, element: u32) -> Option<f32>;
    fn write(&self, device: AudioObjectID, element: u32, volume: f32) -> Result<()>;
}

/// CoreAudio 实现
#[derive(Default)]
pub struct CoreAudioVolume;

impl CoreAudioVolume {
    fn address(element: u32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress {
            mSelector: VOLUME_SELECTOR,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element,
        }
    }

    fn default_output() -> AudioObjectID {
        let addr = AudioObjectPropertyAddress {
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        };
        let mut device = kAudioObjectUnknown;
        let mut size = size_of::<AudioObjectID>() as u32;
        unsafe {
            AudioObjectGetPropertyData(
                kAudioObjectSystemObject,
                &addr,
                0,
                null(),
                &mut size,
                &mut device as *mut _ as *mut c_void,
            );
        }
        device
    }

    fn settable(device: AudioObjectID, element: u32) -> bool {
        let addr = Self::address(element);
        let mut settable: Boolean = 0;
        unsafe { AudioObjectIsPropertySettable(device, &addr, &mut settable) == 0 && settable != 0 }
    }
}

impl VolumeAdapter for CoreAudioVolume {
    fn output_device(&self) -> Option<AudioObjectID> {
        let device = Self::default_output();
        (device != kAudioObjectUnknown).then_some(device)
    }

    fn writable_elements(&self, device: AudioObjectID) -> Vec<u32> {
        // main 可用时只写 main；否则写各个可写的声道
        if Self::settable(device, kAudioObjectPropertyElementMain) {
            return vec![kAudioObjectPropertyElementMain];
        }
        [1u32, 2].into_iter().filter(|&el| Self::settable(device, el)).collect()
    }

    fn read(&self, device: AudioObjectID, element: u32) -> Option<f32> {
        let addr = Self::address(element);
        if unsafe { AudioObjectHasProperty(device, &addr) } == 0 {
            return None;
        }
        let mut volume = 0f32;
        let mut size = size_of::<f32>() as u32;
        let status = unsafe {
            AudioObjectGetPropertyData(device, &addr, 0, null(), &mut size, &mut volume as *mut _ as *mut c_void)
        };
        (status == 0).then_some(volume)
    }

    fn write(&self, device: AudioObjectID, element: u32, volume: f32) -> Result<()> {
        let addr = Self::address(element);
        if unsafe { AudioObjectHasProperty(device, &addr) } == 0 {
            return Err(anyhow!("输出设备不支持音量控制"));
        }
        let clamped = volume.clamp(0.0, 1.0);
        let status =
            unsafe { AudioObjectSetPropertyData(device, &addr, 0, null(), size_of::<f32>() as u32, &clamped as *const _ as *mut c_void) };
        if status == 0 {
            Ok(())
        } else {
            Err(anyhow!("设置输出音量失败：{status}"))
        }
    }
}

/// 录音期间压低输出音量，结束后还原。线程安全，可重复调用
pub struct RecordingVolume {
    adapter: Arc<dyn VolumeAdapter>,
    /// 压低状态与保存的原值
    state: Mutex<Option<Saved>>,
}

impl RecordingVolume {
    pub fn new() -> Self {
        Self { adapter: Arc::new(CoreAudioVolume), state: Mutex::new(None) }
    }

    /// 测试用：注入适配层
    pub fn with_adapter(adapter: Arc<dyn VolumeAdapter>) -> Self {
        Self { adapter, state: Mutex::new(None) }
    }

    /// 压低到 `target`（0.0–1.0）。`target <= 0` 表示不调整，直接返回 false
    pub fn lower(&self, target: f32) -> bool {
        if target <= 0.0 {
            return false;
        }
        let Some(device) = self.adapter.output_device() else { return false };
        let elements = self.adapter.writable_elements(device);
        if elements.is_empty() {
            return false;
        }
        let mut volumes = [0f32; 2];
        for (i, &el) in elements.iter().enumerate() {
            // 读不到原值时放弃这次压低，避免还原时写错值
            let Some(v) = self.adapter.read(device, el) else { return false };
            volumes[i] = v;
        }
        let mut elements_arr = [0u32; 2];
        elements_arr[..elements.len()].copy_from_slice(&elements);
        let saved = Saved { device, elements: elements_arr, volumes, len: elements.len() };

        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        // 已压低时保留原值，只把目标音量写进去
        let ok = elements.iter().all(|&el| self.adapter.write(device, el, target).is_ok());
        if !ok {
            return false;
        }
        if state.is_none() {
            *state = Some(saved);
        }
        true
    }

    /// 还原保存的音量。未压低时为空操作
    pub fn restore(&self) -> bool {
        let saved = {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            state.take()
        };
        let Some(saved) = saved else { return false };
        let mut written = 0usize;
        let mut failed = false;
        for i in 0..saved.len {
            let (el, v) = (saved.elements[i], saved.volumes[i]);
            // 设备已不存在时放弃还原，不写入其他设备
            if self.adapter.read(saved.device, el).is_none() {
                continue;
            }
            written += 1;
            failed |= self.adapter.write(saved.device, el, v).is_err();
        }
        // 一个都没写成功也算失败：空集合上的「全部成功」不是成功
        written > 0 && !failed
    }

    pub fn is_lowered(&self) -> bool {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).is_some()
    }
}

impl Default for RecordingVolume {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[derive(Default)]
    struct Fake {
        device: Mutex<Option<AudioObjectID>>,
        elements: Mutex<Vec<u32>>,
        /// 当前各 element 的音量
        values: Mutex<Vec<(u32, f32)>>,
        writes: AtomicUsize,
        fail_write: bool,
    }

    impl Fake {
        fn new(device: AudioObjectID, elements: Vec<u32>, initial: f32) -> Self {
            Self {
                device: Mutex::new(Some(device)),
                elements: Mutex::new(elements.clone()),
                values: Mutex::new(elements.into_iter().map(|el| (el, initial)).collect()),
                ..Default::default()
            }
        }

        fn value(&self, element: u32) -> f32 {
            self.values.lock().unwrap().iter().find(|(el, _)| *el == element).map(|(_, v)| *v).unwrap_or(0.0)
        }
    }

    impl VolumeAdapter for Fake {
        fn output_device(&self) -> Option<AudioObjectID> {
            *self.device.lock().unwrap()
        }

        fn writable_elements(&self, _device: AudioObjectID) -> Vec<u32> {
            self.elements.lock().unwrap().clone()
        }

        fn read(&self, _device: AudioObjectID, element: u32) -> Option<f32> {
            self.values.lock().unwrap().iter().find(|(el, _)| *el == element).map(|(_, v)| *v)
        }

        fn write(&self, _device: AudioObjectID, element: u32, volume: f32) -> Result<()> {
            if self.fail_write {
                return Err(anyhow!("write failed"));
            }
            self.writes.fetch_add(1, Ordering::SeqCst);
            if let Some(slot) = self.values.lock().unwrap().iter_mut().find(|(el, _)| *el == element) {
                slot.1 = volume.clamp(0.0, 1.0);
            }
            Ok(())
        }
    }

    #[test]
    fn lower_saves_original_and_sets_target() {
        let fake = Arc::new(Fake::new(42, vec![0], 0.13));
        let rv = RecordingVolume::with_adapter(fake.clone());
        assert!(rv.lower(0.15));
        assert!(rv.is_lowered());
        assert_eq!(fake.value(0), 0.15);
        assert_eq!(fake.writes.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn restore_writes_back_saved_volume() {
        let fake = Arc::new(Fake::new(42, vec![0], 0.13));
        let rv = RecordingVolume::with_adapter(fake.clone());
        rv.lower(0.15);
        assert!(rv.restore());
        assert_eq!(fake.value(0), 0.13);
        assert!(!rv.is_lowered());
    }

    #[test]
    fn restore_without_lower_is_noop() {
        let fake = Arc::new(Fake::new(42, vec![0], 0.13));
        let rv = RecordingVolume::with_adapter(fake.clone());
        assert!(!rv.restore());
        assert_eq!(fake.writes.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn double_lower_keeps_original() {
        let fake = Arc::new(Fake::new(42, vec![0], 0.13));
        let rv = RecordingVolume::with_adapter(fake.clone());
        rv.lower(0.15);
        rv.lower(0.4);
        rv.restore();
        assert_eq!(fake.value(0), 0.13);
    }

    #[test]
    fn zero_target_is_noop() {
        let fake = Arc::new(Fake::new(42, vec![0], 0.13));
        let rv = RecordingVolume::with_adapter(fake.clone());
        assert!(!rv.lower(0.0));
        assert_eq!(fake.writes.load(Ordering::SeqCst), 0);
        assert!(!rv.is_lowered());
    }

    #[test]
    fn missing_device_is_noop() {
        let fake = Arc::new(Fake::new(42, vec![0], 0.13));
        *fake.device.lock().unwrap() = None;
        let rv = RecordingVolume::with_adapter(fake.clone());
        assert!(!rv.lower(0.15));
        assert!(!rv.is_lowered());
        assert_eq!(fake.writes.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn unwritable_device_is_noop() {
        let fake = Arc::new(Fake::new(42, vec![0], 0.13));
        *fake.elements.lock().unwrap() = vec![];
        let rv = RecordingVolume::with_adapter(fake.clone());
        assert!(!rv.lower(0.15));
        assert!(!rv.is_lowered());
        assert_eq!(fake.writes.load(Ordering::SeqCst), 0);
    }

    /// 读不到原值时放弃压低：还原才不会写错值
    #[test]
    fn unreadable_original_skips_lowering() {
        struct NoRead;
        impl VolumeAdapter for NoRead {
            fn output_device(&self) -> Option<AudioObjectID> {
                Some(42)
            }
            fn writable_elements(&self, _d: AudioObjectID) -> Vec<u32> {
                vec![0]
            }
            fn read(&self, _d: AudioObjectID, _el: u32) -> Option<f32> {
                None
            }
            fn write(&self, _d: AudioObjectID, _el: u32, _v: f32) -> Result<()> {
                Ok(())
            }
        }
        let rv = RecordingVolume::with_adapter(Arc::new(NoRead));
        assert!(!rv.lower(0.15));
        assert!(!rv.is_lowered());
    }

    #[test]
    fn failed_write_leaves_no_saved_state() {
        let mut fake = Fake::new(42, vec![0], 0.13);
        fake.fail_write = true;
        let fake = Arc::new(fake);
        let rv = RecordingVolume::with_adapter(fake.clone());
        assert!(!rv.lower(0.15));
        assert!(!rv.is_lowered());
        // 没有保存状态，还原不会去写一个错的音量
        assert!(!rv.restore());
        assert_eq!(fake.writes.load(Ordering::SeqCst), 0);
    }

    /// 设备只在左右声道提供音量时，两个声道都要压低和还原
    #[test]
    fn per_channel_elements_are_handled() {
        let fake = Arc::new(Fake::new(42, vec![1, 2], 0.13));
        let rv = RecordingVolume::with_adapter(fake.clone());
        assert!(rv.lower(0.15));
        assert_eq!(fake.value(1), 0.15);
        assert_eq!(fake.value(2), 0.15);
        assert!(rv.restore());
        assert_eq!(fake.value(1), 0.13);
        assert_eq!(fake.value(2), 0.13);
    }

    /// 原设备消失后放弃还原
    #[test]
    fn vanished_device_skips_restore() {
        let fake = Arc::new(Fake::new(42, vec![0], 0.13));
        let rv = RecordingVolume::with_adapter(fake.clone());
        rv.lower(0.15);
        fake.values.lock().unwrap().clear();
        assert!(!rv.restore());
        assert!(!rv.is_lowered());
    }

    /// 还原时目标值按 0.0–1.0 夹紧，不写越界值
    #[test]
    fn out_of_range_values_are_clamped() {
        let fake = Arc::new(Fake::new(42, vec![0], 0.13));
        let rv = RecordingVolume::with_adapter(fake.clone());
        assert!(rv.lower(1.5));
        assert_eq!(fake.value(0), 1.0);
    }
}
