import AVFoundation
import AudioToolbox
import CoreAudio

/// CoreAudio 输入设备；UID 存设置里，拔掉后自动回退系统默认
struct Microphone: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID

    static var selectedUID: String { UserDefaults.standard.string(forKey: "micUID") ?? "" }

    static func all() -> [Microphone] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("CADefaultDeviceAggregate"),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Microphone(id: uid, name: name, deviceID: id)
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

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

/// AudioQueue 直接按 16kHz/mono/Int16 采集（系统负责重采样），按 UID 指定输入设备
final class Recorder {
    private let callbackQueue = DispatchQueue(label: "voicekey.recorder")
    private var queue: AudioQueueRef?
    private var pending: [Int16] = []
    private var continuation: AsyncStream<[Int16]>.Continuation?
    /// 每 20ms 帧的音量（0...1），在采集队列回调
    var onLevel: ((Float) -> Void)?

    func start() throws -> AsyncStream<[Int16]> {
        let (stream, cont) = AsyncStream<[Int16]>.makeStream()
        var format = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var q: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&q, &format, 0, callbackQueue) { [weak self] q, buffer, _, _, _ in
            guard let self, let continuation = self.continuation else { return }
            let count = Int(buffer.pointee.mAudioDataByteSize) / 2
            self.pending += UnsafeBufferPointer(start: buffer.pointee.mAudioData.assumingMemoryBound(to: Int16.self), count: count)
            while self.pending.count >= FrameConverter.frame {
                let frame = Array(self.pending.prefix(FrameConverter.frame))
                continuation.yield(frame)
                self.onLevel?(Recorder.level(frame))
                self.pending.removeFirst(FrameConverter.frame)
            }
            AudioQueueEnqueueBuffer(q, buffer, 0, nil)
        }
        guard status == noErr, let q else { throw ASRError("麦克风打开失败 \(status)") }
        let uid = Microphone.selectedUID
        if !uid.isEmpty, Microphone.all().contains(where: { $0.id == uid }) {
            var cf = uid as CFString
            AudioQueueSetProperty(q, kAudioQueueProperty_CurrentDevice, &cf, UInt32(MemoryLayout<CFString>.size))
        }
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(q, UInt32(FrameConverter.frame * 2 * 2), &buffer)
            if let buffer { AudioQueueEnqueueBuffer(q, buffer, 0, nil) }
        }
        callbackQueue.sync {
            pending = []
            continuation = cont
        }
        let started = AudioQueueStart(q, nil)
        guard started == noErr else {
            AudioQueueDispose(q, true)
            callbackQueue.sync { continuation = nil }
            throw ASRError("麦克风启动失败 \(started)")
        }
        queue = q
        return stream
    }

    /// RMS → dBFS，-50dB 以下视为静音，-10dB 封顶
    static func level(_ frame: [Int16]) -> Float {
        let sum = frame.reduce(Float(0)) { $0 + Float($1) * Float($1) }
        let rms = (sum / Float(frame.count)).squareRoot() / 32768
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 50) / 40, 0), 1)
    }

    func stop() {
        guard let q = queue else { return }
        queue = nil
        AudioQueueStop(q, true)
        callbackQueue.sync {
            if !pending.isEmpty {
                continuation?.yield(pending + [Int16](repeating: 0, count: FrameConverter.frame - pending.count))
            }
            pending = []
            continuation?.finish()
            continuation = nil
        }
        AudioQueueDispose(q, true)
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
