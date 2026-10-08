import AVFoundation
import VoiceKeyCore

/// 渠道测试：用内置录音按实时速度跑一遍，不依赖麦克风
final class ChannelTest: ObservableObject {
    static let shared = ChannelTest()
    @Published private(set) var results: [String: String] = [:]

    func run(_ ch: Channel) {
        guard let path = Bundle.main.path(forResource: "sample", ofType: "wav"),
              let engine = RecognitionEngine(rawValue: ch.engine) else { return }
        results[ch.id] = "测试中…"
        let t0 = Date()
        var first: Double?
        try? RecognitionSession.recognize(file: URL(fileURLWithPath: path), engine: engine) { e in
            DispatchQueue.main.async {
                let me = ChannelTest.shared
                let t = Date().timeIntervalSince(t0)
                switch e {
                case .partial: if first == nil { first = t }
                case .final(let s):
                    me.results[ch.id] = s.isEmpty ? "无结果" : String(format: "首字 %.2fs · 完成 %.2fs", first ?? t, t)
                    Bus.log("test \(ch.id)/\(ch.engine) ok first=\(first ?? -1) total=\(t): \(s)")
                case .failure(let m):
                    me.results[ch.id] = "失败：\(SessionManager.friendly(m))"
                    Bus.log("test \(ch.id)/\(ch.engine) failed: \(m)")
                }
            }
        }
    }
}

/// -fakemic：用内置录音（后接 3 秒静音，循环）代替麦克风送入识别，便于无人值守验证
final class FakeMic {
    let rate: Double
    private let samples: [Float]
    private var timer: DispatchSourceTimer?
    private var pos = 0

    init?() {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "wav"),
              let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
        rate = f.processingFormat.sampleRate
        samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength))) + [Float](repeating: 0, count: Int(rate * 3))
    }

    func start(_ sink: @escaping (UnsafePointer<Float>, Int) -> Void) {
        stop()
        let n = Int(rate / 50)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [Float](repeating: 0, count: n)
            for i in 0..<n { chunk[i] = self.samples[(self.pos + i) % self.samples.count] }
            self.pos = (self.pos + n) % self.samples.count
            chunk.withUnsafeBufferPointer { sink($0.baseAddress!, n) }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// -script "start a,b 1.5;wait 4;stop;wait 6;commit a"：按键盘的方式发命令，验证协议链路
enum Harness {
    static func run(_ script: String) {
        let steps = script.split(separator: ";").map { $0.split(separator: " ").map(String.init) }
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 1.5)
            for s in steps {
                guard let op = s.first else { continue }
                let utt = LiveState.load()?.utterance?.id
                switch op {
                case "wait": Thread.sleep(forTimeInterval: Double(s.dropFirst().first ?? "1") ?? 1)
                case "start":
                    let ids = s.count > 1 && s[1] != "-" ? s[1].split(separator: ",").map(String.init) : nil
                    send(.start, channels: ids, silenceStop: s.count > 2 ? Double(s[2]) : nil)
                case "commit": send(.commit, utt: utt, channel: s.count > 1 ? s[1] : nil)
                default:
                    guard let o = Command.Op(rawValue: op) else { Bus.log("harness: unknown \(op)"); continue }
                    send(o, utt: utt)
                }
                Thread.sleep(forTimeInterval: 0.3)
                if let st = LiveState.load() {
                    let u = st.utterance.map { u in "#\(u.id) \(u.phase.rawValue) stop=\(u.stopReason?.rawValue ?? "-") err=\(u.error?.rawValue ?? "-") " + u.rows.map { "\($0.channel):\($0.state.rawValue):\($0.ms ?? -1):\($0.text)" }.joined(separator: " | ") } ?? "nil"
                    Bus.log("harness after \(s.joined(separator: " ")): ack=\(st.ackSeq) active=\(st.session.active) intr=\(st.session.interrupted) exp=\(st.session.expiresAt.map { String(format: "%.0f", $0 - VK.now) } ?? "-") utt=\(u)")
                }
            }
            Bus.log("harness done")
            SessionManager.mirrorLog()
        }
    }

    private static func send(_ op: Command.Op, utt: Int? = nil, channels: [String]? = nil, silenceStop: Double? = nil, channel: String? = nil) {
        DispatchQueue.main.sync { _ = CommandQueue.send(op, utt: utt, channels: channels, silenceStop: silenceStop, channel: channel) }
    }
}
