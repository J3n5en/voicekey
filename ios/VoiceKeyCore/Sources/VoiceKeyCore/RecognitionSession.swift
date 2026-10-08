import Foundation
import VoiceKeyCoreFFI

public let coreVersion = String(cString: vk_version())

public enum RecognitionEngine: String, CaseIterable, Sendable {
    case doubao, wetype, qwen, baidu, sogou, iflytek

    /// 预热（建连、取凭据等），不阻塞
    public func prewarm() { _ = vk_prewarm(rawValue) }
}

public enum RecognitionEvent: Equatable, Sendable {
    /// 当前整句的中间结果，覆盖上一次
    case partial(String)
    case final(String)
    case failure(String)
}

public enum RecognitionError: Error {
    case invalidArgument
}

/// 事件在 Rust 工作线程上回调；每个会话恰好一次 .final 或 .failure，之后不再回调并释放 handler
public typealias RecognitionHandler = @Sendable (RecognitionEvent) -> Void

/// 一次识别：push 任意采样率的单声道 f32，finish 后等定稿。push/finish 线程安全
public final class RecognitionSession: @unchecked Sendable {
    private let raw: OpaquePointer

    public init(engine: RecognitionEngine, sampleRate: Double, onEvent: @escaping RecognitionHandler) throws {
        guard sampleRate >= 1, sampleRate <= Double(UInt32.max) else { throw RecognitionError.invalidArgument }
        let ctx = Handler.retain(onEvent)
        guard let raw = vk_session_start(engine.rawValue, UInt32(sampleRate), eventThunk, releaseThunk, ctx) else {
            Handler.release(ctx)
            throw RecognitionError.invalidArgument
        }
        self.raw = raw
    }

    deinit { vk_session_free(raw) }

    public func push(_ samples: UnsafePointer<Float>, count: Int) {
        vk_session_push(raw, samples, count)
    }

    public func push(_ samples: UnsafeBufferPointer<Float>) {
        guard let p = samples.baseAddress else { return }
        push(p, count: samples.count)
    }

    /// 说完：冲刷尾帧，之后的 push 被忽略；可重复调用
    public func finish() { vk_session_finish(raw) }

    /// 按实时速度识别 wav 文件（渠道自检），文件错误经 .failure 返回
    public static func recognize(file: URL, engine: RecognitionEngine, onEvent: @escaping RecognitionHandler) throws {
        let ctx = Handler.retain(onEvent)
        guard vk_run_file(engine.rawValue, file.path, eventThunk, releaseThunk, ctx) else {
            Handler.release(ctx)
            throw RecognitionError.invalidArgument
        }
    }
}

private final class Handler {
    let fn: RecognitionHandler
    init(_ fn: @escaping RecognitionHandler) { self.fn = fn }

    static func retain(_ fn: @escaping RecognitionHandler) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(Handler(fn)).toOpaque()
    }

    static func release(_ ctx: UnsafeMutableRawPointer) {
        Unmanaged<Handler>.fromOpaque(ctx).release()
    }
}

private let eventThunk: vk_event_fn = { ctx, kind, text in
    guard let ctx else { return }
    let s = text.map { String(cString: $0) } ?? ""
    let event: RecognitionEvent
    switch kind {
    case Int32(VK_EVENT_PARTIAL.rawValue): event = .partial(s)
    case Int32(VK_EVENT_FINAL.rawValue): event = .final(s)
    default: event = .failure(s)
    }
    Unmanaged<Handler>.fromOpaque(ctx).takeUnretainedValue().fn(event)
}

private let releaseThunk: vk_release_fn = { ctx in
    if let ctx { Handler.release(ctx) }
}
