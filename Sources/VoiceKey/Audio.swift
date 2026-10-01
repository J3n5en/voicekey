import AVFoundation

/// 任意输入格式 → 16kHz/mono/Int16，按 20ms（320 样本）切帧
final class FrameConverter {
    static let frame = 320
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter
    private var pending: [Int16] = []

    init(from input: AVAudioFormat) throws {
        guard let c = AVAudioConverter(from: input, to: Self.format) else { throw ASRError("不支持的音频格式") }
        converter = c
    }

    func push(_ buffer: AVAudioPCMBuffer) -> [[Int16]] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }
        var fed = false
        _ = converter.convert(to: out, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        pending += UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength))
        var frames: [[Int16]] = []
        while pending.count >= Self.frame {
            frames.append(Array(pending.prefix(Self.frame)))
            pending.removeFirst(Self.frame)
        }
        return frames
    }

    /// 不足一帧的尾巴补零
    func flush() -> [Int16]? {
        guard !pending.isEmpty else { return nil }
        defer { pending = [] }
        return pending + [Int16](repeating: 0, count: Self.frame - pending.count)
    }
}

final class Recorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: FrameConverter?
    private var continuation: AsyncStream<[Int16]>.Continuation?

    func start() throws -> AsyncStream<[Int16]> {
        let (stream, cont) = AsyncStream<[Int16]>.makeStream()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw ASRError("没有可用的麦克风") }
        let conv = try FrameConverter(from: format)
        lock.withLock {
            converter = conv
            continuation = cont
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.withLock {
                guard let converter = self.converter, let continuation = self.continuation else { return }
                for f in converter.push(buffer) { continuation.yield(f) }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            if let tail = converter?.flush() { continuation?.yield(tail) }
            continuation?.finish()
            continuation = nil
            converter = nil
        }
    }
}

/// 调试用：读音频文件，按实时节奏喂帧
func fileFrames(_ url: URL, realtime: Bool) throws -> AsyncStream<[Int16]> {
    let file = try AVAudioFile(forReading: url)
    let conv = try FrameConverter(from: file.processingFormat)
    var frames: [[Int16]] = []
    while file.framePosition < file.length {
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
        try file.read(into: buf)
        frames += conv.push(buf)
    }
    if let tail = conv.flush() { frames.append(tail) }
    return AsyncStream { cont in
        Task {
            for f in frames {
                cont.yield(f)
                if realtime { try? await Task.sleep(for: .milliseconds(20)) }
            }
            cont.finish()
        }
    }
}
