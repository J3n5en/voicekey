//! 录音期间系统输出音量 ducking：平滑过渡、可打断，并且只恢复自己仍然拥有的状态。

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const FADE_FRAME_MS: usize = 20;
const FADE_FRAME: Duration = Duration::from_millis(FADE_FRAME_MS as u64);
const FADE_MIN_MS: f32 = 250.0;
const FADE_MAX_MS: f32 = 450.0;
const FADE_MIN_RELATIVE_TRAVEL: f32 = 0.10;
const FADE_MAX_RELATIVE_TRAVEL: f32 = 0.90;
// 首帧收到命令后立即写入，所以 N 步只有 N-1 个等待间隔；20ms 粒度下实际钳在约 260..440ms，避免超过 450ms 上限。
const MIN_FADE_STEPS: usize = 14;
const MAX_FADE_STEPS: usize = 23;
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
    total_steps: usize,
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

    fn configure(&mut self, active: bool, fraction: f32) {
        let fraction = fraction.clamp(0.0, 1.0);
        let fraction_changed = (self.fraction - fraction).abs() > VOLUME_EPSILON;
        let active_changed = self.active != active;
        self.fraction = fraction;

        if active_changed {
            self.set_active(active);
        } else if active && fraction_changed && !self.yielded {
            // 只重定向 VoiceKey 仍拥有的过渡；下一 tick 会先核对实际音量，用户手调后不会被重新抢回。
            self.transition = None;
            self.duck_settled = false;
        }
        // active=false 时只记住下次比例；正在进行的恢复必须继续回 original，不能被 slider 改写目标。
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
        let total_steps = fade_steps(&lease.original, &lease.applied, &target);
        self.transition = Some(Transition {
            start: lease.applied.clone(),
            target,
            step: 0,
            total_steps,
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
        let linear = transition.step as f32 / transition.total_steps as f32;
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
        if transition.step >= transition.total_steps {
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
        // 进程退出没有时间等待最长约 450ms 的动态动画；只在仍拥有音量时立即恢复，避免永久留在低音量。
        self.restore_immediately(backend);
        self.lease = None;
        self.transition = None;
        self.duck_settled = false;
    }
}

/// 根据“这一次真正还要移动多少”决定动画时长，而不是直接看 slider 的静态百分比。
///
/// 距离始终除以本轮首次接管时的 original：因此初次 duck、恢复、录音中改比例和中途反向都以同一基线衡量，
/// 不会把已经压低后的中间值当成新基线。相对路程 10%..90% 线性映射到目标 250..450ms，超出范围钳住；
/// 这样大幅压低更柔和，而只改一点比例或刚开始就反向时不会拖着跑一段过长的动画。
fn fade_steps(
    original: &OutputVolumeSnapshot,
    start: &OutputVolumeSnapshot,
    target: &OutputVolumeSnapshot,
) -> usize {
    let relative_travel = original
        .values
        .iter()
        .zip(&start.values)
        .zip(&target.values)
        .filter_map(|((original, start), target)| {
            (original.value > VOLUME_EPSILON)
                .then_some((target.value - start.value).abs() / original.value)
        })
        .fold(0.0_f32, f32::max);
    let relative_travel = relative_travel.clamp(FADE_MIN_RELATIVE_TRAVEL, FADE_MAX_RELATIVE_TRAVEL);
    let progress = (relative_travel - FADE_MIN_RELATIVE_TRAVEL)
        / (FADE_MAX_RELATIVE_TRAVEL - FADE_MIN_RELATIVE_TRAVEL);
    let duration_ms = FADE_MIN_MS + (FADE_MAX_MS - FADE_MIN_MS) * progress;

    // 第 1 帧会立即执行；20ms 无法精确表达 250/450ms，因此实际完成时间量化为约 260..440ms。
    // 上限选择向下钳制而不是放到 460ms，是为了保证“450ms 最长目标”不会再次显得拖拉。
    ((duration_ms / FADE_FRAME_MS as f32).ceil() as usize + 1).clamp(MIN_FADE_STEPS, MAX_FADE_STEPS)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Advance {
    InProgress,
    Finished,
    Failed,
}

enum Command {
    SetActive(bool),
    Configure { active: bool, fraction: f32 },
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

    /// 原子更新启用状态和相对音量比例，避免设置页快速操作时短暂套用旧参数。
    pub fn configure(&self, active: bool, fraction: f32) {
        let _ = self.tx.send(Command::Configure { active, fraction });
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
        Command::Configure { active, fraction } => {
            state.configure(active, fraction);
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
    fn fade_duration_scales_with_actual_relative_travel() {
        let original = snapshot("speaker", 0.8);

        // 10% 路程落在最短档；50% 居中；70%（默认保留 30%）约 400ms；90% 到最长档。
        assert_eq!(
            fade_steps(&original, &original, &snapshot("speaker", 0.72)),
            14
        );
        assert_eq!(
            fade_steps(&original, &original, &snapshot("speaker", 0.4)),
            19
        );
        assert_eq!(
            fade_steps(&original, &original, &snapshot("speaker", 0.24)),
            21
        );
        assert_eq!(
            fade_steps(&original, &original, &snapshot("speaker", 0.08)),
            23
        );

        // 已经压低后只微调 5% 原始音量时，按实际剩余路程走最短档，而不是按 slider 数字重跑长动画。
        assert_eq!(
            fade_steps(
                &original,
                &snapshot("speaker", 0.24),
                &snapshot("speaker", 0.28),
            ),
            14
        );
    }

    #[test]
    fn smooth_duck_and_restore() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.24).abs() < 0.003);

        state.set_active(false);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        assert!(state.lease.is_none());
    }

    #[test]
    fn full_reduction_reaches_zero_and_restores_original() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.0);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!(backend.volume("speaker").abs() < 0.003);

        state.set_active(false);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        assert!(state.lease.is_none());
    }

    #[test]
    fn changing_fraction_after_duck_keeps_original_baseline() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.24).abs() < 0.003);

        state.configure(true, 0.5);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.4).abs() < 0.003);

        state.set_active(false);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
    }

    #[test]
    fn changing_fraction_mid_fade_retargets_without_ratchet() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, 4);
        assert!(backend.volume("speaker") < 0.8);

        state.configure(true, 0.5);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.4).abs() < 0.003);

        state.set_active(false);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
    }

    #[test]
    fn fraction_change_after_manual_volume_change_does_not_reclaim_control() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);

        // 用户先按系统音量键、设置页紧接着改比例；即使 worker 还没轮询到用户修改，也必须让权。
        backend.set_user_volume("speaker", 0.55);
        state.configure(true, 0.5);
        ticks(&mut state, &mut backend, 4);
        assert!(state.yielded);
        assert!(state.lease.is_none());
        assert!((backend.volume("speaker") - 0.55).abs() < 0.003);

        // 只有明确结束再开始下一次录音，才允许用新比例重新接管。
        state.set_active(false);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.275).abs() < 0.003);
    }

    #[test]
    fn fraction_change_during_restore_does_not_move_restore_target() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);

        state.set_active(false);
        ticks(&mut state, &mut backend, 4);
        state.configure(false, 0.5);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        assert!(state.lease.is_none());

        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.4).abs() < 0.003);
    }

    #[test]
    fn interrupted_restore_reverses_without_ratchet() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);

        state.set_active(false);
        ticks(&mut state, &mut backend, 5);
        assert!(backend.volume("speaker") > 0.24);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.24).abs() < 0.003);

        state.set_active(false);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
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
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);

        // 多次反向只能改变当前过渡起点，最初 0.8 的 original lease 不能被中间值替换。
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        assert!(state.lease.is_none());
    }

    #[test]
    fn user_change_yields_until_next_recording() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);

        backend.set_user_volume("speaker", 0.5);
        state.tick(&mut backend);
        assert!(state.yielded);
        assert!(state.lease.is_none());
        ticks(&mut state, &mut backend, 4);
        assert!((backend.volume("speaker") - 0.5).abs() < 0.003);

        state.set_active(false);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
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
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);

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
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.25).abs() < 0.003);
        assert!(state.duck_settled);

        let writes = backend.writes;
        ticks(&mut state, &mut backend, 8);
        assert_eq!(backend.writes, writes, "量化后的实际值不能触发重复 fade");

        state.set_active(false);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        assert!(state.lease.is_none());
    }

    #[test]
    fn device_switch_restores_old_and_ducks_new_baseline() {
        let mut backend = FakeBackend::new("speaker", 0.8);
        let mut state = DuckState::new(0.3);
        state.set_active(true);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);

        backend
            .devices
            .insert("headset".into(), snapshot("headset", 0.6));
        backend.default = "headset".into();
        state.tick(&mut backend);
        assert!((backend.volume("speaker") - 0.8).abs() < 0.003);
        ticks(&mut state, &mut backend, MAX_FADE_STEPS);
        assert!((backend.volume("headset") - 0.18).abs() < 0.003);
    }
}
