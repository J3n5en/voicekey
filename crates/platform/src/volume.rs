//! 录音期间系统输出音量 ducking：平滑过渡、可打断，并且只恢复自己仍然拥有的状态。

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const FADE_STEPS: usize = 18;
const FADE_FRAME: Duration = Duration::from_millis(20);
const HOLD_POLL: Duration = Duration::from_millis(120);
const VOLUME_EPSILON: f32 = 0.002;

#[derive(Clone, Debug)]
pub(crate) struct OutputVolumeValue {
    pub element: u32,
    pub value: f32,
}

/// 平台音量快照同时保留稳定设备标识和本次原生对象 id。
///
/// macOS 的 AudioObjectID 可能在设备重连后变化，因此恢复时两者都要吻合；
/// Windows 没有额外的原生 id，`native_id` 固定为 0，设备 endpoint id 已足够唯一。
#[derive(Clone, Debug)]
pub(crate) struct OutputVolumeSnapshot {
    pub device_id: String,
    pub native_id: u64,
    pub muted: Option<bool>,
    pub values: Vec<OutputVolumeValue>,
}

impl OutputVolumeSnapshot {
    pub(crate) fn same_device(&self, other: &Self) -> bool {
        self.device_id == other.device_id && self.native_id == other.native_id
    }

    pub(crate) fn matches(&self, other: &Self) -> bool {
        self.same_device(other)
            && (self.muted.is_none() || other.muted.is_none() || self.muted == other.muted)
            && self.values.len() == other.values.len()
            && self
                .values
                .iter()
                .zip(&other.values)
                .all(|(a, b)| a.element == b.element && (a.value - b.value).abs() <= VOLUME_EPSILON)
    }

    fn scaled(&self, fraction: f32) -> Self {
        let mut out = self.clone();
        for value in &mut out.values {
            value.value = (value.value * fraction).clamp(0.0, 1.0);
        }
        out
    }

    fn interpolate(&self, target: &Self, progress: f32) -> Self {
        let mut out = self.clone();
        for (value, end) in out.values.iter_mut().zip(&target.values) {
            value.value += (end.value - value.value) * progress;
        }
        out
    }
}

trait Backend {
    fn default_snapshot(&mut self) -> Option<OutputVolumeSnapshot>;
    fn snapshot(&mut self, device: &OutputVolumeSnapshot) -> Option<OutputVolumeSnapshot>;
    fn write(
        &mut self,
        desired: &OutputVolumeSnapshot,
        expected: &OutputVolumeSnapshot,
    ) -> Option<OutputVolumeSnapshot>;
}

struct SystemBackend;

impl Backend for SystemBackend {
    fn default_snapshot(&mut self) -> Option<OutputVolumeSnapshot> {
        crate::imp::output_volume_default()
    }

    fn snapshot(&mut self, device: &OutputVolumeSnapshot) -> Option<OutputVolumeSnapshot> {
        crate::imp::output_volume_for(device)
    }

    fn write(
        &mut self,
        desired: &OutputVolumeSnapshot,
        expected: &OutputVolumeSnapshot,
    ) -> Option<OutputVolumeSnapshot> {
        crate::imp::output_volume_write(desired, expected)
    }
}

#[derive(Clone)]
struct Lease {
    /// 永远是本轮第一次接管该设备时的音量；反复 start/stop 不能把中间值误当新基线，否则会越压越低。
    original: OutputVolumeSnapshot,
    /// VoiceKey 最后一次确认写入的实际值；恢复前必须仍匹配它，用户手调后立即让出控制权。
    applied: OutputVolumeSnapshot,
}

struct Transition {
    start: OutputVolumeSnapshot,
    target: OutputVolumeSnapshot,
    step: usize,
}

struct DuckState {
    active: bool,
    /// 用户在当前一次聆听期间手动改过音量，或开始时设备本就静音/为零后，
    /// 直到下一次 stop -> start 都不再追着用户压低；用户意图始终优先于自动 ducking。
    yielded: bool,
    /// 已完成本轮向下过渡。真实声卡可能把 0..1 标量量化到固定步进，因此“成功写入后的实际值”
    /// 不一定精确等于数学目标；完成后只监控所有权/设备变化，不反复重跑同一段 fade。
    duck_settled: bool,
    fraction: f32,
    lease: Option<Lease>,
    transition: Option<Transition>,
}

impl DuckState {
    fn new(fraction: f32) -> Self {
        Self {
            active: false,
            yielded: false,
            duck_settled: false,
            fraction: fraction.clamp(0.0, 1.0),
            lease: None,
            transition: None,
        }
    }

    fn set_active(&mut self, active: bool) {
        if self.active == active {
            return;
        }
        self.active = active;
        // 改变方向时从“当前实际值”重新起一条 smoothstep，避免快速开始/结束时出现跳变。
        self.transition = None;
        self.duck_settled = false;
        if !active {
            // stop 是一个明确的会话边界：下一次 start 可以重新以用户当前音量为基线。
            self.yielded = false;
        }
    }

    fn quiescent(&self) -> bool {
        self.lease.is_none() && (!self.active || self.yielded)
    }

    fn next_wait(&self) -> Duration {
        if self.transition.is_some() {
            FADE_FRAME
        } else {
            HOLD_POLL
        }
    }

    fn tick<B: Backend>(&mut self, backend: &mut B) {
        if self.active {
            self.tick_active(backend);
        } else {
            self.tick_restore(backend);
        }
    }

    fn tick_active<B: Backend>(&mut self, backend: &mut B) {
        if self.yielded {
            return;
        }

        let Some(default) = backend.default_snapshot() else {
            return;
        };

        if let Some(lease) = &self.lease {
            if !default.same_device(&lease.original) {
                // 默认输出切走后，旧设备已经不可听：若它仍保持我们的值就立即还原，绝不把旧设备音量套到新设备。
                self.restore_immediately(backend);
                self.lease = None;
                self.transition = None;
                self.duck_settled = false;
            }
        }

        if self.lease.is_none() {
            if default.muted == Some(true)
                || self.fraction >= 1.0
                || !default.values.iter().any(|v| v.value > VOLUME_EPSILON)
            {
                // 本轮从“无需调节”的状态开始；若用户随后主动取消静音/升高音量，也不能马上把它再压下去。
                self.yielded = true;
                return;
            }
            self.lease = Some(Lease {
                original: default.clone(),
                applied: default,
            });
            self.duck_settled = false;
        }

        let Some(lease) = &self.lease else { return };
        let Some(current) = backend.snapshot(&lease.original) else {
            return;
        };
        if !current.matches(&lease.applied) {
            // 音量键、控制中心、外设软件等都可能在聆听中改音量；此时用户意图优先，本轮不再自动接管。
            self.lease = None;
            self.transition = None;
            self.yielded = true;
            self.duck_settled = false;
            return;
        }

        if self.duck_settled {
            return;
        }
        let target = lease.original.scaled(self.fraction);
        if self.ensure_transition(target) {
            self.duck_settled = true;
            return;
        }
        if self.advance(backend) == Advance::Finished {
            self.duck_settled = true;
        }
    }

    fn tick_restore<B: Backend>(&mut self, backend: &mut B) {
        let Some(lease) = &self.lease else { return };
        let Some(current) = backend.snapshot(&lease.original) else {
            // 原设备已不可用时不能把旧值套到当前设备，也不能无限轮询一个已拔掉的对象；安全放弃恢复。
            self.lease = None;
            self.transition = None;
            self.duck_settled = false;
            return;
        };
        if !current.matches(&lease.applied) {
            // 用户已经接管，绝不能为了“恢复”覆盖他的最新选择。
            self.lease = None;
            self.transition = None;
            self.duck_settled = false;
            return;
        }
        let target = lease.original.clone();
        if self.ensure_transition(target) {
            self.lease = None;
            return;
        }
        if self.advance(backend) == Advance::Finished {
            // 最后一帧已经由平台层 compare-and-set 成功写入；即使硬件把标量量化到相邻步进，也视为恢复完成。
            self.lease = None;
        }
    }

    /// 返回 true 表示当前实际值已经足够接近目标，不需要再建过渡。
    fn ensure_transition(&mut self, target: OutputVolumeSnapshot) -> bool {
        if self.transition.is_some() {
            return false;
        }
        let Some(lease) = &self.lease else {
            return true;
        };
        if lease.applied.matches(&target) {
            return true;
        }
        self.transition = Some(Transition {
            start: lease.applied.clone(),
            target,
            step: 0,
        });
        false
    }

    fn advance<B: Backend>(&mut self, backend: &mut B) -> Advance {
        let Some(transition) = self.transition.as_mut() else {
            return Advance::Finished;
        };
        let Some(lease) = self.lease.as_mut() else {
            self.transition = None;
            return Advance::Failed;
        };

        transition.step += 1;
        let linear = transition.step as f32 / FADE_STEPS as f32;
        let progress = linear * linear * (3.0 - 2.0 * linear);
        let desired = transition
            .start
            .interpolate(&transition.target, progress.min(1.0));
        match backend.write(&desired, &lease.applied) {
            Some(actual) => lease.applied = actual,
            None => {
                // 写入前后的 compare-and-set 失败通常意味着用户/设备在同一帧发生了变化；让出控制权最安全。
                self.lease = None;
                self.transition = None;
                self.duck_settled = false;
                if self.active {
                    self.yielded = true;
                }
                return Advance::Failed;
            }
        }
        if transition.step >= FADE_STEPS {
            self.transition = None;
            Advance::Finished
        } else {
            Advance::InProgress
        }
    }

    fn restore_immediately<B: Backend>(&mut self, backend: &mut B) {
        let Some(lease) = &self.lease else { return };
        let Some(current) = backend.snapshot(&lease.original) else {
            return;
        };
        if current.matches(&lease.applied) {
            let _ = backend.write(&lease.original, &current);
        }
    }

    fn shutdown<B: Backend>(&mut self, backend: &mut B) {
        // 进程退出没有时间做 360ms 动画；只在仍拥有音量时立即恢复，避免 VoiceKey 退出后把系统永久留在低音量。
        self.restore_immediately(backend);
        self.lease = None;
        self.transition = None;
        self.duck_settled = false;
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Advance {
    InProgress,
    Finished,
    Failed,
}

enum Command {
    SetActive(bool),
    Shutdown,
}

/// 进程级系统音量 ducking 控制器。
///
/// 所有 CoreAudio/WASAPI 操作都固定在同一个工作线程；`set_active` 只发最新意图，因此录音快速开始、结束、
/// 再开始时不会阻塞录音状态机，并会从当时的实际音量平滑反向过渡。
pub struct OutputVolumeDucker {
    tx: Sender<Command>,
    thread: Option<JoinHandle<()>>,
}

impl OutputVolumeDucker {
    pub fn new(fraction: f32) -> Self {
        let (tx, rx) = mpsc::channel();
        let thread = thread::Builder::new()
            .name("voicekey-volume-duck".into())
            .spawn(move || worker(rx, fraction))
            .ok();
        Self { tx, thread }
    }

    pub fn set_active(&self, active: bool) {
        let _ = self.tx.send(Command::SetActive(active));
    }
}

impl Drop for OutputVolumeDucker {
    fn drop(&mut self) {
        let _ = self.tx.send(Command::Shutdown);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn worker(rx: Receiver<Command>, fraction: f32) {
    let mut backend = SystemBackend;
    let mut state = DuckState::new(fraction);
    loop {
        let first = if state.quiescent() {
            match rx.recv() {
                Ok(cmd) => Some(cmd),
                Err(_) => break,
            }
        } else {
            match rx.recv_timeout(state.next_wait()) {
                Ok(cmd) => Some(cmd),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => break,
            }
        };

        if let Some(cmd) = first {
            if apply_command(cmd, &mut state, &mut backend) {
                break;
            }
            // 一口气吃掉积压的 start/stop，按发送顺序更新状态；最后一个意图生效，但中间的 stop 仍能重置让权边界。
            while let Ok(cmd) = rx.try_recv() {
                if apply_command(cmd, &mut state, &mut backend) {
                    return;
                }
            }
        }
        state.tick(&mut backend);
    }
    state.shutdown(&mut backend);
}

fn apply_command<B: Backend>(cmd: Command, state: &mut DuckState, backend: &mut B) -> bool {
    match cmd {
        Command::SetActive(active) => {
            state.set_active(active);
            false
        }
        Command::Shutdown => {
            state.shutdown(backend);
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    struct FakeBackend {
        default: String,
        devices: HashMap<String, OutputVolumeSnapshot>,
        quantize_step: Option<f32>,
        writes: usize,
    }

    impl FakeBackend {
        fn new(id: &str, volume: f32) -> Self {
            let mut devices = HashMap::new();
            devices.insert(id.into(), snapshot(id, volume));
            Self {
                default: id.into(),
                devices,
                quantize_step: None,
                writes: 0,
            }
        }

        fn quantized(id: &str, volume: f32, step: f32) -> Self {
            let mut backend = Self::new(id, volume);
            backend.quantize_step = Some(step);
            backend
        }

        fn volume(&self, id: &str) -> f32 {
            self.devices[id].values[0].value
        }

        fn set_user_volume(&mut self, id: &str, value: f32) {
            self.devices.get_mut(id).unwrap().values[0].value = value;
        }
    }

    impl Backend for FakeBackend {
        fn default_snapshot(&mut self) -> Option<OutputVolumeSnapshot> {
            self.devices.get(&self.default).cloned()
        }

        fn snapshot(&mut self, device: &OutputVolumeSnapshot) -> Option<OutputVolumeSnapshot> {
            self.devices
                .get(&device.device_id)
                .filter(|v| v.native_id == device.native_id)
                .cloned()
        }

        fn write(
            &mut self,
            desired: &OutputVolumeSnapshot,
            expected: &OutputVolumeSnapshot,
        ) -> Option<OutputVolumeSnapshot> {
            let current = self.devices.get(&expected.device_id)?.clone();
            if !current.matches(expected) {
                return None;
            }
            self.writes += 1;
            let mut actual = desired.clone();
            if let Some(step) = self.quantize_step {
                for value in &mut actual.values {
                    value.value = (value.value / step).round() * step;
                }
            }
            self.devices.insert(desired.device_id.clone(), actual);
            self.devices.get(&desired.device_id).cloned()
        }
    }

    fn snapshot(id: &str, volume: f32) -> OutputVolumeSnapshot {
        OutputVolumeSnapshot {
            device_id: id.into(),
            native_id: 1,
            muted: Some(false),
            values: vec![OutputVolumeValue {
                element: 0,
                value: volume,
            }],
        }
    }

    fn ticks(state: &mut DuckState, backend: &mut FakeBackend, n: usize) {
        for _ in 0..n {
            state.tick(backend);
        }
    }

    #[test]
    fn smooth_duck_and_restore() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, FADE_STEPS);
        assert!((backend.volume("speaker") - 0.24).abs() < 0.003);

        state.set_active(false);
        ticks(&mut state, &mut backend, FADE_STEPS);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        assert!(state.lease.is_none());
    }

    #[test]
    fn interrupted_restore_reverses_without_ratchet() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, FADE_STEPS);

        state.set_active(false);
        ticks(&mut state, &mut backend, 5);
        assert!(backend.volume("speaker") > 0.24);
        state.set_active(true);
        ticks(&mut state, &mut backend, FADE_STEPS);
        assert!((backend.volume("speaker") - 0.24).abs() < 0.003);

        state.set_active(false);
        ticks(&mut state, &mut backend, FADE_STEPS);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
    }

    #[test]
    fn repeated_interrupts_mid_fade_keep_first_baseline() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);

        state.set_active(true);
        ticks(&mut state, &mut backend, 4);
        let first_partial = backend.volume("speaker");
        assert!(first_partial < 0.8 && first_partial > 0.24);

        state.set_active(false);
        ticks(&mut state, &mut backend, 3);
        assert!(backend.volume("speaker") > first_partial);

        state.set_active(true);
        ticks(&mut state, &mut backend, 2);
        state.set_active(false);
        ticks(&mut state, &mut backend, FADE_STEPS);

        // 多次反向只能改变当前过渡起点，最初 0.8 的 original lease 不能被中间值替换。
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        assert!(state.lease.is_none());
    }

    #[test]
    fn user_change_yields_until_next_recording() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, FADE_STEPS);

        backend.set_user_volume("speaker", 0.5);
        state.tick(&mut backend);
        assert!(state.yielded);
        assert!(state.lease.is_none());
        ticks(&mut state, &mut backend, 4);
        assert!((backend.volume("speaker") - 0.5).abs() < 0.003);

        state.set_active(false);
        state.set_active(true);
        ticks(&mut state, &mut backend, FADE_STEPS);
        assert!((backend.volume("speaker") - 0.15).abs() < 0.003);
    }

    #[test]
    fn zero_volume_at_start_is_left_to_user_for_whole_recording() {
        let mut backend = FakeBackend::new("speaker", 0.0);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        state.tick(&mut backend);
        assert!(state.yielded);

        // 用户在聆听中主动把原本为零的音量升高，这是明确的新意图，不能立刻再被自动压低。
        backend.set_user_volume("speaker", 0.7);
        ticks(&mut state, &mut backend, 4);
        assert!((backend.volume("speaker") - 0.7).abs() < 0.003);
        assert!(state.lease.is_none());
    }

    #[test]
    fn user_change_during_restore_is_never_overwritten() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, FADE_STEPS);

        state.set_active(false);
        ticks(&mut state, &mut backend, 4);
        backend.set_user_volume("speaker", 0.55);
        state.tick(&mut backend);
        assert!((backend.volume("speaker") - 0.55).abs() < 0.003);
        assert!(state.lease.is_none());
    }

    #[test]
    fn quantized_hardware_settles_once_and_still_restores() {
        let mut backend = FakeBackend::quantized("speaker", 0.8, 0.05);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, FADE_STEPS);
        assert!((backend.volume("speaker") - 0.25).abs() < 0.003);
        assert!(state.duck_settled);

        let writes = backend.writes;
        ticks(&mut state, &mut backend, 8);
        assert_eq!(backend.writes, writes, "量化后的实际值不能触发重复 fade");

        state.set_active(false);
        ticks(&mut state, &mut backend, FADE_STEPS);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        assert!(state.lease.is_none());
    }

    #[test]
    fn device_switch_restores_old_and_ducks_new_baseline() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, FADE_STEPS);

        backend
            .devices
            .insert("headset".into(), snapshot("headset", 0.6));
        backend.default = "headset".into();
        state.tick(&mut backend);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        ticks(&mut state, &mut backend, FADE_STEPS);
        assert!((backend.volume("headset") - 0.18).abs() < 0.003);
    }
}
