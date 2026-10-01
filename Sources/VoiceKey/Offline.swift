import CryptoKit
import Foundation

/// 离线识别资源（仅 Apple 芯片）：引擎库来自本仓库 Release，模型来自字节 CDN，首次选用时下载
@MainActor
final class OfflineAssets: ObservableObject {
    static let shared = OfflineAssets()
    #if arch(arm64)
    nonisolated static let supported = true
    #else
    nonisolated static let supported = false
    #endif

    enum State: Equatable { case missing, downloading(Double), ready, failed(String) }
    @Published private(set) var state: State

    private struct Asset {
        let name: String, url: String, size: Int64
        let sha256: String?, md5: String?
    }

    private nonisolated static let libs = "https://github.com/J3n5en/voicekey/releases/download/offline-libs/"
    private nonisolated static let assets = [
        Asset(name: "libc++_shared.so", url: libs + "libc%2B%2B_shared.so", size: 911_696,
              sha256: "e8373ee43274541efd2d34fe0588d55bf953612e1417ad47cfd2c4bd1aa383d0", md5: nil),
        Asset(name: "libiesapplogger.so", url: libs + "libiesapplogger.so", size: 67_616,
              sha256: "08fc4396d0e80aafd83d646ed875289c5987f68a6b3f0827ba1605d2f12130f2", md5: nil),
        Asset(name: "libaudioeffect.so", url: libs + "libaudioeffect.so", size: 7_462_456,
              sha256: "5303cab48de6ef5db6ace4d54779b0e64f9e2eb6a2600dd41638f6d9b67d110f", md5: nil),
        Asset(name: "model.flute", url: "https://lf3-effectcdn-tos.byteeffecttos.com/obj/ies.fe.effect/b78e55b937a6f7da432097d2d9dc7214?module=model",
              size: 185_377_526, sha256: nil, md5: "b78e55b937a6f7da432097d2d9dc7214"),
    ]
    nonisolated static let dir: URL = {
        let d = appSupportFile("offline")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static var model: URL { dir.appendingPathComponent("model.flute") }

    private nonisolated static func present(_ a: Asset) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(a.name).path)
        return (attrs?[.size] as? NSNumber)?.int64Value == a.size
    }

    nonisolated static var installed: Bool { supported && assets.allSatisfy(present) }

    private var task: Task<Void, Never>?

    private init() { state = Self.installed ? .ready : .missing }

    /// 后台下载，进度见 state
    func download() {
        guard Self.supported, task == nil, !Self.installed else { return }
        task = Task {
            do { try await install() } catch { state = .failed(error.localizedDescription) }
            task = nil
        }
    }

    func install() async throws {
        let total = Self.assets.reduce(0) { $0 + $1.size }
        var done = Self.assets.filter(Self.present).reduce(0) { $0 + $1.size }
        state = .downloading(Double(done) / Double(total))
        for a in Self.assets where !Self.present(a) {
            let base = done
            let tmp = try await Fetcher.fetch(a.url) { n in
                Task { @MainActor in self.state = .downloading(Double(base + n) / Double(total)) }
            }
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard try await Task.detached(operation: { try Self.verify(tmp, a) }).value else {
                throw ASRError("\(a.name) 校验失败")
            }
            let dest = Self.dir.appendingPathComponent(a.name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            done += a.size
        }
        state = .ready
    }

    private nonisolated static func verify(_ url: URL, _ a: Asset) throws -> Bool {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256(), md5 = Insecure.MD5()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
            a.sha256 != nil ? sha.update(data: chunk) : md5.update(data: chunk)
        }
        let hex = { (d: any Digest) in d.map { String(format: "%02x", $0) }.joined() }
        return a.sha256.map { hex(sha.finalize()) == $0 } ?? (hex(md5.finalize()) == a.md5)
    }
}

/// 带进度的单文件下载，返回临时文件
private final class Fetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (Int64) -> Void
    private var cont: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    private init(progress: @escaping (Int64) -> Void) { self.progress = progress }

    static func fetch(_ url: String, progress: @escaping (Int64) -> Void) async throws -> URL {
        let f = Fetcher(progress: progress)
        let session = URLSession(configuration: .default, delegate: f, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            f.cont = c
            session.downloadTask(with: URL(string: url)!).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { result = .failure(ASRError("下载失败 HTTP \(status)")); return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        result = Result { try FileManager.default.moveItem(at: location, to: tmp); return tmp }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        cont?.resume(with: error.map { .failure($0) } ?? result ?? .failure(ASRError("下载失败")))
        cont = nil
    }
}

/// 离线识别子进程（VoiceKey --offline-worker <model>，stdin/stdout JSON-lines），崩溃不影响主进程，空闲 5 分钟退出释放内存
final class OfflineWorker: @unchecked Sendable {
    static let shared = OfflineWorker()
    private let queue = DispatchQueue(label: "voicekey.offline")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var generation = 0

    func prewarm() {
        queue.async { [self] in
            generation += 1
            if process?.isRunning != true { try? launch() }
            scheduleIdle()
        }
    }

    /// 发一条请求，返回 text 字段
    func call(_ op: String, b64: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { c in
            queue.async { [self] in
                c.resume(with: Result { try callSync(op, b64: b64) })
                scheduleIdle()
            }
        }
    }

    private func callSync(_ op: String, b64: String?) throws -> String {
        generation += 1
        if process?.isRunning != true { try launch() }
        var req: [String: Any] = ["op": op]
        if let b64 { req["b64"] = b64 }
        let line = try JSONSerialization.data(withJSONObject: req, options: .withoutEscapingSlashes) + Data([10])
        do { try input?.write(contentsOf: line) } catch { stop(); throw ASRError("离线引擎已退出") }
        guard let reply = readLine(),
              let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        else { stop(); throw ASRError("离线引擎异常退出") }
        guard obj["ok"] as? Bool == true else { throw ASRError("离线引擎错误：\(obj["error"] ?? "未知")") }
        return obj["text"] as? String ?? ""
    }

    private func launch() throws {
        guard OfflineAssets.installed, let exe = Bundle.main.executableURL else { throw ASRError("离线模型未下载") }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--offline-worker", OfflineAssets.model.path]
        p.environment = ProcessInfo.processInfo.environment.merging(["HB_LIBDIR": OfflineAssets.dir.path]) { $1 }
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        buffer.removeAll()
    }

    private func readLine() -> Data? {
        while true {
            if let i = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                return Data(line)
            }
            guard let chunk = output?.availableData, !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }

    private func stop() {
        process?.terminate()
        process = nil
        input = nil
        output = nil
    }

    private func scheduleIdle() {
        let g = generation
        queue.asyncAfter(deadline: .now() + 300) { [self] in if g == generation { stop() } }
    }
}

final class OfflineEngine: ASREngine {
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        guard OfflineAssets.installed else {
            await MainActor.run { OfflineAssets.shared.download() }
            throw ASRError("离线模型未就绪，请在设置中查看下载进度")
        }
        let w = OfflineWorker.shared
        _ = try await w.call("begin")
        do {
            var pcm = Data(), last = ""
            func flush() async throws {
                let text = try await w.call("chunk", b64: pcm.base64EncodedString())
                pcm.removeAll(keepingCapacity: true)
                if !text.isEmpty, text != last { last = text; partial(text) }
            }
            for await frame in audio {
                frame.withUnsafeBytes { pcm.append(contentsOf: $0) }
                if pcm.count >= 3200 { try await flush() } // 100ms，引擎按此粒度处理
            }
            if !pcm.isEmpty { try await flush() }
            return try await w.call("end")
        } catch {
            _ = try? await w.call("cancel")
            throw error
        }
    }
}
