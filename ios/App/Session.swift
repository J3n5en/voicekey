import AVFoundation
import UIKit
import VoiceKeyCore

/// 会话管理：常开麦克风保活，按键盘命令识别，结果写入 state.json（协议见 ios/PROTOCOL.md）
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published private(set) var active = false
    @Published private(set) var interrupted = false
    @Published private(set) var since: Double?
    @Published private(set) var lastActivity = VK.now
    @Published private(set) var endReason: LiveState.EndReason?
    @Published private(set) var history: [HistoryItem] = Bus.read([HistoryItem].self, VK.File.history) ?? []
    /// 由键盘拉起：会话页提示点左上角返回
    @Published var openedFromKeyboard = false
    @Published var config = Config.load() {
        didSet { if config != oldValue { config.save(); publish() } }
    }

    /// 测试用：-idlesec N 覆盖闲置秒数
    private let idleOverride = Launch.double("-idlesec")
    var idleSeconds: Double { idleOverride ?? Double(config.idleMinutes * 60) }
    var expiresAt: Double? {
        guard active else { return nil }
        let busy = utt.map { $0.phase == .recording || $0.phase == .finalizing } ?? false
        return Idle.expiry(lastActivity: lastActivity, seconds: idleSeconds, busy: busy, now: VK.now)
    }

    private let launch = UUID().uuidString
    private var ackSeq = 0
    private var nextUtt = 1
    private var endedAt: Double?
    private var recoverPending = false
    private var audio = AVAudioEngine()
    private var utt: Utt?
    private var idleTimer: Timer?
    private var levelTimer: Timer?
    private var heartbeat: Timer?
    private var bg: UIBackgroundTaskIdentifier = .invalid
    private var fake: FakeMic?

    // 音频线程与主线程共享，受 lock 保护
    private let lock = NSLock()
    private var rate: Double = 48000
    private var feeds: [RecognitionSession] = []
    private var recording: [Int16] = []
    private var detector: SilenceDetector?
    private var level: Float = 0
    /// 每句最多保留 3 分钟录音供重试
    private var maxSamples: Int { Int(rate * 180) }

    private init() {
        let old = LiveState.load()
        ackSeq = max(old?.ackSeq ?? 0, Bus.read(CommandQueue.self, VK.File.cmd)?.maxSeq ?? 0)
        nextUtt = (old?.utterance?.id ?? 0) + 1
        if let o = old?.session, o.active {
            if let e = o.expiresAt, e <= VK.now {
                endReason = .idle
                endedAt = e
            } else {
                recoverPending = true
            }
        } else {
            endReason = old?.session.endReason
            endedAt = old?.session.endedAt
        }
        if Launch.has("-fakemic") { fake = FakeMic() }

        Bus.observe(VK.Note.cmd) { [weak self] in self?.drain() }
        Bus.observe(VK.Note.ping) { [weak self] in
            self?.drain()
            self?.publish()
        }
        Bus.observe(VK.Note.config) { [weak self] in
            guard let self else { return }
            let c = Config.load()
            if c != self.config { self.config = c }
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in self?.interruption(n) }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Bus.log("mediaServicesWereReset")
            self?.rebuild(newEngine: true)
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
            guard let self, n.object as AnyObject? === self.audio else { return }
            Bus.log("engine configuration change")
            self.rebuild(newEngine: false)
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { n in
            let s = AVAudioSession.sharedInstance()
            Bus.log("route change \(n.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? "") in=\(s.currentRoute.inputs.map(\.portType.rawValue)) out=\(s.currentRoute.outputs.map(\.portType.rawValue))")
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.becameActive() }
        Bus.log("session init launch=\(launch) ack=\(ackSeq) recover=\(recoverPending) last=\(old?.session.endReason?.rawValue ?? "-")")
        publish()
        Self.mirrorLog()
    }

    // MARK: 会话

    var micGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    /// 开启会话；麦克风未授权或音频启动失败返回 false
    @discardableResult
    func arm() -> Bool {
        if active { return true }
        guard micGranted else {
            Bus.log("arm: mic not granted")
            endReason = .micDenied
            publish()
            return false
        }
        do {
            try activateAudioSession()
            try startEngine()
        } catch {
            Bus.log("arm failed state=\(UIApplication.shared.applicationState.rawValue): \(error)")
            endReason = .failed
            publish()
            return false
        }
        active = true
        interrupted = false
        since = VK.now
        endReason = nil
        endedAt = nil
        lastActivity = VK.now
        for c in config.enabled { RecognitionEngine(rawValue: c.engine)?.prewarm() }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.checkIdle() }
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.beat() }
        let s = AVAudioSession.sharedInstance()
        Bus.log("armed in=\(s.currentRoute.inputs.map(\.portType.rawValue)) out=\(s.currentRoute.outputs.map(\.portType.rawValue)) rate=\(rate) appState=\(UIApplication.shared.applicationState.rawValue)")
        publish()
        return true
    }

    /// 结束会话并关麦（橙点熄灭）；定稿中的识别继续回结果
    func disarm(_ reason: LiveState.EndReason) {
        guard active else { return }
        if utt?.phase == .recording { stopSegment(.interrupted) }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        fake?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        idleTimer?.invalidate()
        heartbeat?.invalidate()
        active = false
        interrupted = false
        endReason = reason
        endedAt = VK.now
        Bus.log("disarmed \(reason.rawValue) after \(Int(VK.now - (since ?? VK.now)))s state=\(UIApplication.shared.applicationState.rawValue)")
        publish()
        Self.mirrorLog()
    }

    func touch() {
        lastActivity = VK.now
    }

    private func activateAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        // 不带 allowBluetoothHFP：连着蓝牙耳机时用手机麦克风，耳机保持 A2DP 音质
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try s.setActive(true)
        if let m = s.availableInputs?.first(where: { $0.portType == .builtInMic }), s.preferredInput?.portType != .builtInMic {
            try? s.setPreferredInput(m)
        }
    }

    private func startEngine() throws {
        audio.stop()
        let input = audio.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw NSError(domain: "VoiceKey", code: 1, userInfo: [NSLocalizedDescriptionKey: "no input format"]) }
        input.removeTap(onBus: 0)
        let real = fake == nil
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard real, let self, let ch = buf.floatChannelData else { return }
            self.ingest(ch[0], Int(buf.frameLength))
        }
        lock.lock()
        rate = fake?.rate ?? fmt.sampleRate
        lock.unlock()
        audio.prepare()
        try audio.start()
        fake?.start { [weak self] p, n in self?.ingest(p, n) }
    }

    private func checkIdle() {
        guard active, let e = expiresAt, e <= VK.now else { return }
        disarm(.idle)
    }

    private func beat() {
        let st = UIApplication.shared.applicationState
        Bus.log("alive \(Int(VK.now - (since ?? VK.now)))s running=\(audio.isRunning) interrupted=\(interrupted) state=\(st.rawValue) mem=\(String(format: "%.1f", Bus.footprintMB()))MB")
        Self.mirrorLog()
        if active, !interrupted, !audio.isRunning {
            Bus.log("engine stopped unexpectedly")
            interrupted = true
            resume(attempt: 0)
        }
    }

    /// iOS 17 的 devicectl 拉不到 App Group 容器，镜像一份到 App 自己的容器
    static func mirrorLog() {
        guard let src = Bus.dir?.appendingPathComponent("log.txt") else { return }
        let dst = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/log.txt")
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    // MARK: 打断与恢复

    private func interruption(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let reason = n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
        Bus.log("interruption \(type == .began ? "began" : "ended") reason=\(reason.map { "\($0)" } ?? "-") running=\(audio.isRunning)")
        guard active else { return }
        if type == .began {
            interrupted = true
            if utt?.phase == .recording { stopSegment(.interrupted) }
            publish()
        } else {
            resume(attempt: 0)
        }
    }

    /// 被打断后重新拿麦克风；后台多次失败则结束会话，键盘下次点麦克风时拉起主 App 重开
    private func resume(attempt: Int) {
        guard active, interrupted else { return }
        if tryResume() { return }
        let delays = [1.0, 3.0]
        if attempt < delays.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in self?.resume(attempt: attempt + 1) }
        } else if UIApplication.shared.applicationState == .background {
            disarm(.interrupted)
        } else {
            publish()
        }
    }

    private func tryResume() -> Bool {
        do {
            try activateAudioSession()
            if !audio.isRunning { try startEngine() }
            interrupted = false
            Bus.log("resumed state=\(UIApplication.shared.applicationState.rawValue)")
            publish()
            return true
        } catch {
            Bus.log("resume failed state=\(UIApplication.shared.applicationState.rawValue): \(error)")
            return false
        }
    }

    private func rebuild(newEngine: Bool) {
        guard active else { return }
        if utt?.phase == .recording { stopSegment(.interrupted) }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        if newEngine { audio = AVAudioEngine() }
        interrupted = true
        resume(attempt: 0)
    }

    private func becameActive() {
        history = Bus.read([HistoryItem].self, VK.File.history) ?? history
        if recoverPending {
            recoverPending = false
            Bus.log("recover session after relaunch")
            arm()
        } else if active, interrupted || !audio.isRunning {
            interrupted = true
            resume(attempt: 0)
        }
    }

    // MARK: 命令

    private func drain() {
        guard let q = Bus.read(CommandQueue.self, VK.File.cmd) else { return }
        let cmds = q.pending(after: ackSeq)
        guard !cmds.isEmpty else { return }
        for c in cmds {
            ackSeq = c.seq
            if VK.now - c.at > 30 {
                Bus.log("cmd #\(c.seq) \(c.op.rawValue) stale, skipped")
                continue
            }
            Bus.log("cmd #\(c.seq) \(c.op.rawValue) utt=\(c.utt.map(String.init) ?? "-") state=\(UIApplication.shared.applicationState.rawValue)")
            handle(c)
        }
        publish()
    }

    private func handle(_ c: Command) {
        touch()
        let current = utt.map { c.utt == $0.id } ?? false
        switch c.op {
        case .start: start(c)
        case .stop: if current, utt?.phase == .recording { stopSegment(.user) }
        case .continue: if current, let u = utt, u.phase == .finalizing || u.phase == .done { beginSegment(u) }
        case .retry: if current { retry() }
        case .close: if current { closeUtterance() }
        case .commit:
            if current, let u = utt, let r = u.rows.first(where: { $0.channel.id == c.channel }) {
                record(u, r)
                if u.rows.count > 1 { config.lastPick = r.channel.id }
                closeUtterance()
            }
        case .touch: break
        case .endSession: disarm(.user)
        }
    }

    private func start(_ c: Command) {
        closeUtterance()
        let u = Utt(id: nextUtt, startSeq: c.seq, silenceStop: (c.silenceStop ?? 0) > 0 ? c.silenceStop : nil)
        nextUtt += 1
        utt = u
        func fail(_ e: LiveState.StartError) {
            u.phase = .failed
            u.error = e
            Bus.log("start #\(u.id) failed: \(e.rawValue)")
        }
        if !active, !arm() { return fail(.noSession) }
        if interrupted, !tryResume() { return fail(.micBusy) }
        let chans = config.resolve(c.channels)
        guard !chans.isEmpty else { return fail(.noChannel) }
        u.rows = chans.map { Utt.Row(channel: $0) }
        lock.lock()
        recording = []
        lock.unlock()
        if bg == .invalid { bg = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackgroundTask() } }
        beginSegment(u)
        Bus.log("start #\(u.id) \(chans.map(\.engine)) silence=\(u.silenceStop ?? 0) rate=\(rate)")
    }

    private func beginSegment(_ u: Utt) {
        lock.lock()
        let from = recording.count, sr = rate
        lock.unlock()
        let seg = u.audio.count
        u.audio.append(from..<from)
        var cores: [RecognitionSession] = []
        for r in u.rows.indices {
            u.rows[r].segs.append(Segment())
            if let core = makeCore(u.id, r, seg, engine: u.rows[r].channel.engine, rate: sr) {
                u.rows[r].cores[seg] = core
                cores.append(core)
            } else {
                u.rows[r].segs[seg].state = .error
                u.rows[r].segs[seg].error = "识别失败"
            }
        }
        lock.lock()
        feeds = cores
        detector = u.silenceStop.map(SilenceDetector.init(hold:))
        lock.unlock()
        u.phase = .recording
        u.stopReason = nil
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.publish() }
        publish()
    }

    private func stopSegment(_ reason: LiveState.StopReason) {
        guard let u = utt, u.phase == .recording else { return }
        lock.lock()
        let cores = feeds
        feeds = []
        detector = nil
        let end = recording.count
        lock.unlock()
        levelTimer?.invalidate()
        cores.forEach { $0.finish() }
        let seg = u.audio.count - 1
        u.audio[seg] = u.audio[seg].lowerBound..<end
        let now = VK.now
        for r in u.rows.indices where u.rows[r].segs[seg].state == .listening {
            u.rows[r].segs[seg].state = .finalizing
            u.rows[r].segs[seg].stoppedAt = now
        }
        u.phase = .finalizing
        u.stopReason = reason
        Bus.log("stop #\(u.id) \(reason.rawValue) \(String(format: "%.1f", Double(end - u.audio[seg].lowerBound) / rate))s")
        settle(u)
        publish()
    }

    private func retry() {
        guard let u = utt, u.phase == .done, u.retryable else { return }
        lock.lock()
        let sr = rate, samples = recording
        lock.unlock()
        let now = VK.now
        for r in u.rows.indices {
            for s in u.rows[r].segs.indices where u.rows[r].segs[s].state == .error {
                let range = u.audio[s]
                guard range.upperBound <= samples.count, let core = makeCore(u.id, r, s, engine: u.rows[r].channel.engine, rate: sr) else { continue }
                u.rows[r].segs[s] = Segment(state: .finalizing, stoppedAt: now)
                u.rows[r].cores[s] = core
                let pcm = Array(samples[range])
                DispatchQueue.global(qos: .userInitiated).async {
                    // 约 2 倍实时速度回放保留的录音
                    let chunk = max(1, Int(sr / 10))
                    var i = 0
                    while i < pcm.count {
                        let f = pcm[i..<min(i + chunk, pcm.count)].map { Float($0) / 32767 }
                        f.withUnsafeBufferPointer { core.push($0) }
                        i += chunk
                        usleep(50_000)
                    }
                    core.finish()
                }
            }
        }
        u.phase = .finalizing
        Bus.log("retry #\(u.id)")
        settle(u)
    }

    private func closeUtterance() {
        guard utt != nil else { return }
        lock.lock()
        feeds = []
        detector = nil
        recording = []
        lock.unlock()
        levelTimer?.invalidate()
        utt = nil
        endBackgroundTask()
    }

    private func makeCore(_ id: Int, _ r: Int, _ seg: Int, engine: String, rate: Double) -> RecognitionSession? {
        do {
            return try RecognitionSession(engine: RecognitionEngine(rawValue: engine) ?? .wetype, sampleRate: rate) { e in
                DispatchQueue.main.async { SessionManager.shared.event(id, r, seg, e) }
            }
        } catch {
            Bus.log("core start failed \(engine) rate=\(rate): \(error)")
            return nil
        }
    }

    private func event(_ id: Int, _ r: Int, _ seg: Int, _ e: RecognitionEvent) {
        guard let u = utt, u.id == id, r < u.rows.count, seg < u.rows[r].segs.count else { return }
        var s = u.rows[r].segs[seg]
        switch e {
        case .partial(let t):
            guard s.state == .listening || s.state == .finalizing else { return }
            s.text = t
        case .final(let t):
            s.text = t
            s.state = .final
            s.doneAt = VK.now
            u.rows[r].cores[seg] = nil
            Bus.log("final #\(id) \(u.rows[r].channel.id)/\(seg): \(t)")
        case .failure(let m):
            s.state = .error
            s.error = Self.friendly(m)
            s.doneAt = VK.now
            u.rows[r].cores[seg] = nil
            Bus.log("error #\(id) \(u.rows[r].channel.id)/\(seg): \(m)")
        }
        u.rows[r].segs[seg] = s
        settle(u)
        publish()
    }

    /// 全部定稿或失败后进入 done；单渠道定稿自动记入最近上屏
    private func settle(_ u: Utt) {
        guard u.phase == .finalizing,
              !u.rows.contains(where: { $0.segs.contains { $0.state == .listening || $0.state == .finalizing } }) else { return }
        u.phase = .done
        lock.lock()
        u.retryable = recording.count < maxSamples
        lock.unlock()
        touch()
        if u.rows.count == 1, let r = u.rows.first, Segment.aggregate(r.segs).state == .final { record(u, r) }
        endBackgroundTask()
    }

    private func record(_ u: Utt, _ r: Utt.Row) {
        let text = Segment.aggregate(r.segs).text
        guard !u.recorded, !text.isEmpty else { return }
        u.recorded = true
        // 键盘清空输入框时也会写入，先取文件里最新的
        history = Bus.read([HistoryItem].self, VK.File.history) ?? history
        history.insert(HistoryItem(text: text, channel: r.channel.name, at: VK.now), at: 0)
        history = Array(history.prefix(20))
        Bus.write(history, VK.File.history)
    }

    private func endBackgroundTask() {
        if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        bg = .invalid
    }

    // MARK: 音频线程

    private func ingest(_ p: UnsafePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += p[i] * p[i] }
        let rms = (sum / Float(n)).squareRoot()
        var done = false
        lock.lock()
        level = rms
        if !feeds.isEmpty {
            for c in feeds { c.push(p, count: n) }
            if recording.count + n <= maxSamples {
                for i in 0..<n { recording.append(Int16(max(-1, min(1, p[i])) * 32767)) }
            }
            if detector?.feed(rms: rms, duration: Double(n) / rate) == true {
                detector = nil
                done = true
            }
        }
        lock.unlock()
        if done { DispatchQueue.main.async { self.stopSegment(.silence) } }
    }

    // MARK: 状态

    private func publish() {
        lock.lock()
        let lv = level
        lock.unlock()
        let s = LiveState(
            launch: launch, updatedAt: VK.now, ackSeq: ackSeq,
            session: .init(active: active, since: since, expiresAt: expiresAt, idleMinutes: config.idleMinutes,
                           interrupted: interrupted, endReason: active ? nil : endReason, endedAt: active ? nil : endedAt),
            utterance: utt?.wire(level: min(1, lv * 8)))
        Bus.write(s, VK.File.state)
        Bus.post(VK.Note.state)
    }

    /// 识别错误原文只进日志，界面只给简短原因
    static func friendly(_ m: String) -> String {
        let l = m.lowercased()
        let net = ["timed out", "timeout", "dns", "connect", "network", "tls", "resolve", "offline", "unreachable", "eof", "reset"]
        return net.contains { l.contains($0) } ? "网络不可用" : "识别失败"
    }
}

/// 一句话：每个渠道一行，每行按「接着说」分段
private final class Utt {
    struct Row {
        let channel: Channel
        var segs: [Segment] = []
        var cores: [Int: RecognitionSession] = [:]
    }

    let id: Int
    let startSeq: Int
    let silenceStop: Double?
    var rows: [Row] = []
    /// 每段对应的录音区间，所有渠道共用
    var audio: [Range<Int>] = []
    var phase: LiveState.Phase = .recording
    var stopReason: LiveState.StopReason?
    var error: LiveState.StartError?
    var retryable = true
    var recorded = false

    init(id: Int, startSeq: Int, silenceStop: Double?) {
        self.id = id
        self.startSeq = startSeq
        self.silenceStop = silenceStop
    }

    func wire(level: Float) -> LiveState.Utterance {
        LiveState.Utterance(
            id: id, startSeq: startSeq, phase: phase, stopReason: stopReason, silenceStop: silenceStop,
            level: phase == .recording ? level : 0,
            rows: rows.map { r in
                let a = Segment.aggregate(r.segs)
                return .init(channel: r.channel.id, name: r.channel.name, text: a.text, state: a.state, error: a.error, ms: a.ms)
            },
            error: error, retryable: retryable)
    }
}

/// 启动参数
enum Launch {
    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }
    static func value(_ flag: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static func double(_ flag: String) -> Double? { value(flag).flatMap(Double.init) }
}
