use coreaudio_sys::*;
use std::ffi::c_void;
use std::mem::{offset_of, size_of};
use std::ptr::{null, null_mut};
use std::sync::{mpsc, OnceLock};
use std::time::Duration;

#[derive(Debug, PartialEq, Eq)]
struct Device {
    id: AudioObjectID,
    name: Option<String>,
    channels: Vec<u32>,
}

#[derive(Debug, PartialEq, Eq)]
struct Snapshot {
    devices: Vec<Device>,
    default: AudioObjectID,
}

impl Snapshot {
    fn inputs(&self) -> impl Iterator<Item = &Device> {
        self.devices.iter().filter(|d| d.name.is_some() && d.channels.iter().any(|&n| n > 0))
    }

    fn microphones(&self) -> Vec<String> {
        self.inputs().filter_map(|d| d.name.clone()).collect()
    }
}

fn address(selector: u32, scope: u32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress {
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain,
    }
}

// u64 storage keeps AudioBufferList aligned; callers only read within the returned byte size.
fn property(id: AudioObjectID, addr: &AudioObjectPropertyAddress) -> Option<(Vec<u64>, usize)> {
    let mut size = 0;
    unsafe {
        if AudioObjectGetPropertyDataSize(id, addr, 0, null(), &mut size) != 0 {
            return None;
        }
        let mut data = vec![0u64; (size as usize).div_ceil(size_of::<u64>())];
        if AudioObjectGetPropertyData(id, addr, 0, null(), &mut size, data.as_mut_ptr().cast()) != 0 {
            return None;
        }
        Some((data, size as usize))
    }
}

fn ids(selector: u32) -> Option<Vec<AudioObjectID>> {
    let (data, size) = property(kAudioObjectSystemObject, &address(selector, kAudioObjectPropertyScopeGlobal))?;
    Some(unsafe { std::slice::from_raw_parts(data.as_ptr().cast(), size / size_of::<AudioObjectID>()) }.to_vec())
}

fn channels(id: AudioObjectID) -> Option<Vec<u32>> {
    let addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput);
    let (data, size) = property(id, &addr)?;
    if size < size_of::<u32>() {
        return None;
    }
    let ptr = data.as_ptr().cast::<u8>();
    let count = unsafe { ptr.cast::<u32>().read() } as usize;
    let offset = offset_of!(AudioBufferList, mBuffers);
    if count > size.saturating_sub(offset) / size_of::<AudioBuffer>() {
        return None;
    }
    Some((0..count).map(|i| unsafe {
        ptr.add(offset + i * size_of::<AudioBuffer>()).cast::<AudioBuffer>().read().mNumberChannels
    }).collect())
}

fn name(id: AudioObjectID) -> Option<String> {
    let (data, size) = property(id, &address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal))?;
    if size != size_of::<CFStringRef>() {
        return None;
    }
    unsafe {
        let value = data.as_ptr().cast::<CFStringRef>().read();
        if value.is_null() {
            return None;
        }
        let len = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), kCFStringEncodingUTF8) + 1;
        let mut buf = vec![0u8; len as usize];
        let ok = CFStringGetCString(value, buf.as_mut_ptr().cast(), len, kCFStringEncodingUTF8);
        CFRelease(value.cast());
        if ok == 0 {
            return None;
        }
        Some(std::ffi::CStr::from_ptr(buf.as_ptr().cast()).to_string_lossy().into_owned())
    }
}

fn snapshot() -> Option<Snapshot> {
    let mut devices = ids(kAudioHardwarePropertyDevices)?;
    devices.sort_unstable();
    Some(Snapshot {
        devices: devices.into_iter().map(|id| Device {
            id,
            name: name(id),
            channels: channels(id).unwrap_or_default(),
        }).collect(),
        default: ids(kAudioHardwarePropertyDefaultInputDevice).and_then(|ids| ids.first().copied()).unwrap_or(0),
    })
}

pub(super) fn microphones() -> Vec<String> {
    snapshot().map(|s| s.microphones()).unwrap_or_default()
}

fn publish_change(previous: &mut Option<Snapshot>, current: Snapshot, on_change: impl FnOnce(Vec<String>)) {
    let changed = previous.as_ref().map(|old| old.default != current.default || !old.inputs().eq(current.inputs())).unwrap_or(true);
    if changed {
        on_change(current.microphones());
    }
    *previous = Some(current);
}

static CHANGED: OnceLock<mpsc::SyncSender<()>> = OnceLock::new();

unsafe extern "C" fn changed(_: AudioObjectID, _: u32, _: *const AudioObjectPropertyAddress, _: *mut c_void) -> OSStatus {
    if let Some(tx) = CHANGED.get() {
        let _ = tx.try_send(());
    }
    0
}

struct Listener(AudioObjectID, AudioObjectPropertyAddress);

impl Listener {
    fn new(id: AudioObjectID, selector: u32, scope: u32) -> Option<Self> {
        let addr = address(selector, scope);
        let status = unsafe { AudioObjectAddPropertyListener(id, &addr, Some(changed), null_mut()) };
        (status == 0).then_some(Self(id, addr))
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        // Callback uses only a process-lifetime sender, never a pointer to this listener.
        unsafe { AudioObjectRemovePropertyListener(self.0, &self.1, Some(changed), null_mut()); }
    }
}

/// One process-lifetime monitor. No AudioUnit/stream is opened, including for zero-input Bluetooth devices.
pub fn watch_microphones(on_change: impl Fn(Vec<String>) + Send + 'static) {
    let (tx, rx) = mpsc::sync_channel(1);
    if CHANGED.set(tx).is_err() {
        return;
    }
    std::thread::spawn(move || {
        let _system: Vec<_> = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
            .into_iter().filter_map(|s| Listener::new(kAudioObjectSystemObject, s, kAudioObjectPropertyScopeGlobal)).collect();
        let mut listeners: Vec<Listener> = Vec::new();
        let mut previous = None;
        loop {
            if let Some(current) = snapshot() {
                // Keep output-only/zero-channel IDs subscribed: A2DP -> HFP/LE input can keep the same ID.
                listeners.retain(|l| current.devices.iter().any(|d| d.id == l.0));
                for device in &current.devices {
                    if !listeners.iter().any(|l| l.0 == device.id) {
                        if let Some(l) = Listener::new(device.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput) {
                            listeners.push(l);
                        }
                    }
                }
                publish_change(&mut previous, current, &on_change);
            }
            // Also reconcile when a driver misses a notification or a listener is not supported yet.
            let _ = rx.recv_timeout(Duration::from_secs(2));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headset(channels: Vec<u32>) -> Snapshot {
        Snapshot { devices: vec![Device { id: 42, name: Some("Bluetooth LE headset".into()), channels }], default: 42 }
    }

    #[test]
    fn connected_zero_channel_device_becomes_visible_without_reconnecting() {
        let pending = headset(vec![0]);
        assert!(pending.microphones().is_empty());
        let ready = headset(vec![1]);
        assert_eq!(pending.devices[0].id, ready.devices[0].id);
        assert_ne!(pending, ready); // Monitor emits even though the hardware device list is unchanged.
        assert_eq!(ready.microphones(), ["Bluetooth LE headset"]);
        assert_eq!(ready, headset(vec![1])); // Stable snapshots do not reopen the meter.
    }

    #[test]
    fn default_switch_and_disconnect_change_snapshot() {
        let before = headset(vec![1]);
        let mut after = headset(vec![1]);
        after.default = 9;
        assert_ne!(before, after);
        assert_eq!(before.microphones(), after.microphones());
        after.devices.clear();
        assert!(after.microphones().is_empty());
        assert_ne!(before, after);
    }

    #[test]
    fn empty_input_configuration_is_retained_for_later_readiness() {
        let pending = headset(vec![]);
        assert_eq!(pending.devices.len(), 1);
        assert!(pending.microphones().is_empty());
        assert_eq!(headset(vec![0, 1]).microphones(), ["Bluetooth LE headset"]);
    }

    #[test]
    fn monitor_publishes_late_input_and_disconnect_but_not_identical_snapshots() {
        let mut previous = None;
        let mut published = Vec::new();
        for current in [headset(vec![]), headset(vec![0]), headset(vec![1]), headset(vec![1]), headset(vec![])] {
            publish_change(&mut previous, current, |mics| published.push(mics));
        }
        assert_eq!(published, vec![vec![], vec!["Bluetooth LE headset".to_string()], vec![]]);
    }

    #[test]
    fn output_only_changes_do_not_publish_but_input_id_and_default_changes_do() {
        let mut previous = Some(headset(vec![1]));
        let mut current = headset(vec![1]);
        current.devices.push(Device { id: 99, name: Some("Display".into()), channels: vec![] });
        publish_change(&mut previous, current, |_| panic!("output-only change"));
        let mut current = headset(vec![1]);
        current.devices[0].id = 43;
        let mut count = 0;
        publish_change(&mut previous, current, |_| count += 1);
        let mut current = headset(vec![1]);
        current.devices[0].id = 43;
        current.default = 43;
        publish_change(&mut previous, current, |_| count += 1);
        assert_eq!(count, 2);
    }

    #[test]
    #[ignore = "reads this Mac's CoreAudio devices; no recording or permission request"]
    fn live_device_monitor_without_capture() {
        let initial = snapshot().expect("CoreAudio snapshot");
        eprintln!("CoreAudio snapshot: {initial:?}");
        let (tx, rx) = mpsc::channel();
        watch_microphones(move |mics| { let _ = tx.send(mics); });
        let names = rx.recv_timeout(Duration::from_secs(5)).expect("initial device event");
        eprintln!("Microphone event: {names:?}");
        for device in initial.devices {
            let addr = address(kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal);
            if let Some((data, size)) = property(device.id, &addr) {
                assert!(size >= size_of::<u32>());
                let running = unsafe { data.as_ptr().cast::<u32>().read() };
                assert_eq!(running, 0, "monitor must not start device {} in this process", device.id);
            }
        }
    }
}
