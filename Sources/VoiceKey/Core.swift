import COpus
import Foundation

struct ASRError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 一次识别：消费 16kHz/mono/Int16 的 20ms 帧流，流结束即松手，返回最终文本
protocol ASREngine: AnyObject {
    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String
}

final class Opus {
    static let voip: Int32 = 2048
    static let audio: Int32 = 2049
    private let encoder: OpaquePointer
    private var buffer = [UInt8](repeating: 0, count: 4000)

    init(application: Int32, bitrate: Int32, complexity: Int32) throws {
        guard let enc = copus_create(16000, application, bitrate, complexity) else {
            throw ASRError("Opus 编码器创建失败")
        }
        encoder = enc
    }

    deinit { opus_encoder_destroy(encoder) }

    func encode(_ pcm: [Int16]) throws -> Data {
        let n = opus_encode(encoder, pcm, Int32(pcm.count), &buffer, Int32(buffer.count))
        guard n > 0 else { throw ASRError("Opus 编码失败 \(n)") }
        return Data(buffer[0..<Int(n)])
    }
}

// MARK: - protobuf

func uvarint(_ value: UInt64) -> Data {
    var n = value
    var out = Data()
    while n >= 0x80 {
        out.append(UInt8(n & 0x7f) | 0x80)
        n >>= 7
    }
    out.append(UInt8(n))
    return out
}

final class PBuf {
    private(set) var data = Data()

    @discardableResult func v(_ field: UInt64, _ value: UInt64) -> PBuf {
        data += uvarint(field << 3) + uvarint(value)
        return self
    }

    @discardableResult func s(_ field: UInt64, _ value: Data) -> PBuf {
        data += uvarint(field << 3 | 2) + uvarint(UInt64(value.count)) + value
        return self
    }

    @discardableResult func s(_ field: UInt64, _ value: String) -> PBuf { s(field, Data(value.utf8)) }
    @discardableResult func m(_ field: UInt64, _ sub: PBuf) -> PBuf { s(field, sub.data) }
}

enum PBValue {
    case varint(UInt64)
    case bytes(Data)
    case fixed
}

func readVarint(_ buf: [UInt8], _ i: inout Int) throws -> UInt64 {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    while true {
        guard i < buf.count, shift < 64 else { throw ASRError("protobuf varint 截断") }
        let b = buf[i]
        i += 1
        value |= UInt64(b & 0x7f) << shift
        if b < 0x80 { return value }
        shift += 7
    }
}

func pbParse(_ data: Data) throws -> [(field: Int, value: PBValue)] {
    let buf = [UInt8](data)
    var out: [(Int, PBValue)] = []
    var i = 0
    while i < buf.count {
        let tag = try readVarint(buf, &i)
        let field = Int(tag >> 3)
        switch tag & 7 {
        case 0: out.append((field, .varint(try readVarint(buf, &i))))
        case 1, 5:
            i += tag & 7 == 1 ? 8 : 4
            guard i <= buf.count else { throw ASRError("protobuf 字段截断") }
            out.append((field, .fixed))
        case 2:
            let n = Int(try readVarint(buf, &i))
            guard n >= 0, i + n <= buf.count else { throw ASRError("protobuf 字段截断") }
            out.append((field, .bytes(Data(buf[i..<i + n]))))
            i += n
        default: throw ASRError("不支持的 protobuf wire type")
        }
    }
    return out
}

extension Array where Element == (field: Int, value: PBValue) {
    func bytes(_ field: Int) -> Data? {
        for f in self where f.field == field { if case let .bytes(d) = f.value { return d } }
        return nil
    }

    func varint(_ field: Int) -> UInt64? {
        for f in self where f.field == field { if case let .varint(v) = f.value { return v } }
        return nil
    }

    func string(_ field: Int) -> String? { bytes(field).map { String(decoding: $0, as: UTF8.self) } }
}

// MARK: - WebSocket

final class WebSocket {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, protocols: [String] = []) {
        var request = request
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
    }

    var alive: Bool { task.state == .running && task.closeCode == .invalid }

    func send(_ data: Data) async throws { try await task.send(.data(data)) }

    func receive(timeout: TimeInterval) async throws -> Data {
        let task = self.task
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                switch try await task.receive() {
                case let .data(d): return d
                case let .string(s): return Data(s.utf8)
                @unknown default: return Data()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                task.cancel(with: .goingAway, reason: nil)
                throw ASRError("服务器响应超时")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}

func appSupportFile(_ name: String) -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoiceKey", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

extension Data {
    var hexUpper: String { map { String(format: "%02X", $0) }.joined() }
}
