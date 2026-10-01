import CommonCrypto
import CryptoKit
import Foundation

/// 微信输入法云端识别（伪装 Mac 客户端）：protobuf 包 HTTP over WSS + snappy + AES-256-ECB + secp128r1 ECDH
final class WeTypeEngine: ASREngine {
    private static let opusHeader = Data("#!OPUS_RAW_V1".utf8) + Data([2, 1, 0])
    private static let packetsPerRequest = 6
    private var client: WeTypeClient?

    /// 握手约 400ms，连接留着给下次用；失效则首包失败时重连重发
    private func channel(fresh: Bool) async throws -> (WeTypeClient, reused: Bool) {
        if !fresh, let c = client, c.alive { return (c, true) }
        client?.close()
        client = nil
        let c = try await WeTypeClient.open()
        client = c
        return (c, false)
    }

    func prewarm() {
        Task { _ = try? await channel(fresh: false) }
    }

    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        var (c, reused) = try await channel(fresh: false)
        let encoder = try Opus(application: Opus.audio, bitrate: 64000, complexity: 9)
        let voiceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var packets: [Data] = []
        var seq = 0, totalBytes = 0
        var text = "", polished = ""

        func send(_ opus: Data?, seq: Int, isEnd: Bool) async throws {
            let packet = WeTypeClient.VoicePacket(voiceId: voiceId, opus: opus, seq: seq, totalBytes: totalBytes, isEnd: isEnd)
            let reply: (text: String, polished: String)
            do {
                reply = try await c.voice(packet)
            } catch {
                guard reused else { throw error }
                c.close()
                (c, _) = try await channel(fresh: true)
                reply = try await c.voice(packet)
            }
            reused = false
            if !reply.text.isEmpty { text = reply.text; partial(text) }
            if !reply.polished.isEmpty { polished = reply.polished }
        }
        func upload(_ batch: [Data], isEnd: Bool) async throws {
            seq += 1
            var framed = seq == 1 ? Self.opusHeader : Data()
            for p in batch { framed += Data([UInt8(p.count & 0xff), UInt8(p.count >> 8)]) + p }
            totalBytes += framed.count
            try await send(framed, seq: seq, isEnd: isEnd)
        }

        do {
            for await frame in audio {
                try Task.checkCancellation()
                packets.append(try encoder.encode(frame))
                if packets.count >= Self.packetsPerRequest {
                    try await upload(packets, isEnd: false)
                    packets.removeAll()
                }
            }
            while packets.count > Self.packetsPerRequest {
                try await upload(Array(packets.prefix(Self.packetsPerRequest)), isEnd: false)
                packets.removeFirst(Self.packetsPerRequest)
            }
            try await upload(packets, isEnd: true)
            // 松手后以空包轮询整理过的定稿，实测首轮即返回
            for _ in 0..<8 where polished.isEmpty {
                try await Task.sleep(for: .milliseconds(250))
                try await send(nil, seq: 0, isEnd: true)
            }
        } catch {
            c.close()
            if client === c { client = nil }
            throw error
        }
        return polished.isEmpty ? text : polished
    }
}

final class WeTypeClient {
    struct VoicePacket {
        let voiceId: String
        let opus: Data?
        let seq: Int
        let totalBytes: Int
        let isEnd: Bool
    }

    private struct Identity: Codable { let device: String; let uin: String }

    private static let host = "wetype.weixin.qq.com"
    private static let signKey = "zN7rB3bL4pO8jW1o"
    private static let bootKey = Data("D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6".utf8)
    private static let version = "2.2.3(657)"
    private static let osType = "5", platform = "2", deviceModel = "Mac16,12"
    private static let cmdDH = 2_147_483_646, cmdUin = 0x7FFF_FDFD, cmdNotify = 8074, cmdVoice = 4548
    private static let identityFile = appSupportFile("wetype.json")

    private let ws: WebSocket
    private var task = 0
    private var uin = "0"
    private var device = ""
    private var sessionKey: Data?
    private var serverPublic = ""
    private var uinToken = ""

    private init(ws: WebSocket) { self.ws = ws }

    var alive: Bool { ws.alive }
    func close() { ws.close() }

    static func open() async throws -> WeTypeClient {
        let ws = WebSocket(request: URLRequest(url: URL(string: "wss://\(host)/")!), protocols: ["wxws_pb"])
        let c = WeTypeClient(ws: ws)
        do {
            try await c.handshake()
            return c
        } catch {
            ws.close()
            throw error
        }
    }

    private func handshake() async throws {
        _ = try await roundtrip("/timestamp", Data(), cmd: 0)
        let saved = (try? Data(contentsOf: Self.identityFile)).flatMap { try? JSONDecoder().decode(Identity.self, from: $0) }
        if let saved {
            device = saved.device
            uin = saved.uin
            do { try await exchangeKey(needUin: false) } catch { try await register() }
        } else {
            try await register()
        }
        if saved?.device != device || saved?.uin != uin {
            try? JSONEncoder().encode(Identity(device: device, uin: uin)).write(to: Self.identityFile)
        }
        _ = try await roundtrip("/api_v2", aesEncrypt(key(), Data()), cmd: Self.cmdNotify)
    }

    private func key() throws -> Data {
        guard let sessionKey else { throw ASRError("微信会话密钥缺失") }
        return sessionKey
    }

    private func exchangeKey(needUin: Bool) async throws {
        let (priv, pubHex) = Secp128r1.generateKeyPair()
        let req = PBuf()
        req.s(1, pubHex).s(2, pubHex)
        if needUin { req.v(3, 1) }
        req.s(4, device)
        if !needUin { req.v(5, UInt64(uin) ?? 0) }
        req.s(7, "").s(8, Self.deviceModel).s(9, "")
        let body = try await request("/oauth_pubkey_v2", aesEncrypt(Self.bootKey, req.data), cmd: Self.cmdDH)
        let f = try pbParse(try aesDecrypt(Self.bootKey, body))
        guard let server = f.string(2) else { throw ASRError("微信密钥交换不完整") }
        let token = f.string(4)
        if needUin, token == nil { throw ASRError("微信密钥交换不完整") }
        serverPublic = server
        uinToken = token ?? ""
        sessionKey = Data(try Secp128r1.sharedX(priv, serverPublic).utf8)
    }

    private func register() async throws {
        uin = "0"
        let body = "MAC" + String(repeating: "0", count: 17 - Self.deviceModel.count) + Self.deviceModel
            + String((0..<12).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
        device = body + md5Upper(Data((body + Self.signKey).utf8))
        try await exchangeKey(needUin: true)
        let req = PBuf()
        req.s(1, device).s(2, serverPublic).s(4, uinToken)
        let r = try await request("/gen_uin_v2", aesEncrypt(key(), req.data), cmd: Self.cmdUin, token: uinToken)
        guard let issued = try pbParse(try aesDecrypt(key(), r)).varint(2), issued != 0 else {
            throw ASRError("微信未签发 UIN")
        }
        uin = String(issued)
    }

    func voice(_ p: VoicePacket) async throws -> (text: String, polished: String) {
        let inner = PBuf()
        inner.s(2, p.voiceId)
        if let opus = p.opus, !opus.isEmpty { inner.s(4, opus) }
        inner.v(5, 5)
        if p.isEnd { inner.v(6, 1) }
        inner.v(7, UInt64(p.seq))
        if p.totalBytes > 0 { inner.v(11, UInt64(p.totalBytes)) }
        inner.v(22, 1).v(23, 1).v(24, 1)
        let outer = PBuf()
        outer.m(1, inner)

        let r = try await roundtrip("/api_v2", aesEncrypt(key(), snappyCompress(outer.data)), cmd: Self.cmdVoice, compress: "2")
        guard r.status == 200, !r.body.isEmpty else { throw ASRError("微信语音请求失败 \(r.status)") }
        var plain = try aesDecrypt(key(), r.body)
        if (r.headers["Kb-CompressionType"] ?? r.headers["CompressionType"]) == "2" {
            plain = try snappyDecompress(plain)
        }
        let top = try pbParse(plain)
        let f = try pbParse(top.bytes(1) ?? plain)
        return (f.string(4) ?? "", f.string(14) ?? "")
    }

    private func request(_ path: String, _ body: Data, cmd: Int, token: String = "") async throws -> Data {
        let r = try await roundtrip(path, body, cmd: cmd, token: token)
        guard r.status == 200, !r.body.isEmpty else {
            throw ASRError("微信 \(path) 状态 \(r.status)")
        }
        return r.body
    }

    /// 一条 WSS 上严格一问一答
    private func roundtrip(_ path: String, _ body: Data, cmd: Int, compress: String = "1",
                           token: String = "") async throws -> (status: UInt64, headers: [String: String], body: Data) {
        let dh = cmd == Self.cmdDH, genUin = cmd == Self.cmdUin
        if !(dh || genUin) { task += 1 }
        let taskId = dh || genUin ? cmd : task
        let trace = String((0..<16).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
        let md5 = md5Upper(body)
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        let signed: [Any] = dh ? [Self.osType, Self.version, Self.platform, ts, md5, trace, cmd]
            : genUin ? [Self.osType, Self.version, Self.platform, ts, md5, token, trace, cmd]
            : [Self.osType, Self.version, Self.platform, cmd, 0, ts, md5, uin, trace, taskId]
        let sign = SHA256.hash(data: Data((signed.map { "\($0)" }.joined() + Self.signKey).utf8))

        var headers: [(String, String)] = []
        if !token.isEmpty { headers.append(("Kb-GenUinToken", token)) }
        headers.append(("Kb-Uin", uin))
        if dh || genUin { headers.append(("Kb-DeviceCodeRestrictionV2", "1")) }
        if !dh {
            if let sessionKey { headers.append(("Kb-SharedKeySuffix", String(String(decoding: sessionKey, as: UTF8.self).suffix(4)))) }
            headers += [("Kb-CmdId", String(cmd)), ("Kb-SubCmdId", "0")]
        }
        headers += [
            ("Kb-OsType", Self.osType), ("Kb-Version", Self.version), ("Kb-SystemVersion", "27.0.0"),
            ("Kb-PackageType", "3"), ("Use_DebugNet", "0"), ("Kb-TimeStamp", ts), ("Kb-BodyMd5", md5),
            ("Kb-TraceId", trace), ("Kb-TaskId", String(taskId)), ("Kb-Scene", "2"),
            ("Kb-Sign", Data(sign).hexUpper), ("Content-Length", String(body.count)),
            ("Kb-CompressionType", compress), ("Content-Type", "application/octet-stream"), ("HOST", Self.host),
        ]
        let http = PBuf()
        http.s(1, "POST").s(3, path).s(4, "")
        for (k, v) in headers {
            let h = PBuf()
            h.s(1, k).s(2, v)
            http.m(5, h)
        }
        http.s(6, body)
        let frame = PBuf()
        frame.v(1, 0).v(2, 0).v(3, UInt64(taskId)).m(5, http)
        try await ws.send(frame.data)

        let fields = try pbParse(try await ws.receive(timeout: 15)).bytes(4).map(pbParse) ?? []
        var out: [String: String] = [:]
        for f in fields where f.field != 5 {
            guard case let .bytes(d) = f.value, let kv = try? pbParse(d), kv.count >= 2,
                  case let .bytes(k) = kv[0].value, case let .bytes(v) = kv[1].value else { continue }
            out[String(decoding: k, as: UTF8.self)] = String(decoding: v, as: UTF8.self)
        }
        return (fields.varint(2) ?? 0, out, fields.bytes(5) ?? Data())
    }
}

// MARK: - 加密 / 压缩

private func md5Upper(_ data: Data) -> String { Data(Insecure.MD5.hash(data: data)).hexUpper }

private func aesCrypt(_ op: CCOperation, _ key: Data, _ data: Data) throws -> Data {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { d in
            key.withUnsafeBytes { k in
                CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        k.baseAddress, key.count, nil, d.baseAddress, data.count, o.baseAddress, o.count, &moved)
            }
        }
    }
    guard status == kCCSuccess else { throw ASRError("AES 失败 \(status)") }
    return out.prefix(moved)
}

private func aesEncrypt(_ key: Data, _ data: Data) throws -> Data { try aesCrypt(CCOperation(kCCEncrypt), key, data) }
private func aesDecrypt(_ key: Data, _ data: Data) throws -> Data { try aesCrypt(CCOperation(kCCDecrypt), key, data) }

/// 上行只发字面量块
private func snappyCompress(_ data: Data) -> Data {
    var out = uvarint(UInt64(data.count))
    let bytes = [UInt8](data)
    for i in stride(from: 0, to: bytes.count, by: 60) {
        let chunk = bytes[i..<min(i + 60, bytes.count)]
        out.append(UInt8((chunk.count - 1) << 2))
        out += chunk
    }
    return out
}

private func snappyDecompress(_ data: Data) throws -> Data {
    let buf = [UInt8](data)
    var i = 0
    let length = Int(try readVarint(buf, &i))
    var out = [UInt8]()
    out.reserveCapacity(length)
    func byte() throws -> Int {
        guard i < buf.count else { throw ASRError("snappy 截断") }
        defer { i += 1 }
        return Int(buf[i])
    }
    func copy(_ offset: Int, _ n: Int) throws {
        guard offset > 0, offset <= out.count, out.count + n <= length else { throw ASRError("snappy 复制越界") }
        for _ in 0..<n { out.append(out[out.count - offset]) }
    }
    while i < buf.count {
        let tag = try byte()
        switch tag & 3 {
        case 0:
            var n = tag >> 2
            if n >= 60 {
                let width = n - 59
                n = 0
                for k in 0..<width { n |= try byte() << (8 * k) }
            }
            n += 1
            guard i + n <= buf.count, out.count + n <= length else { throw ASRError("snappy 字面量越界") }
            out += buf[i..<i + n]
            i += n
        case 1:
            let lo = try byte()
            try copy(((tag >> 5) << 8) | lo, ((tag >> 2) & 7) + 4)
        case 2:
            let off = try byte() | (try byte() << 8)
            try copy(off, (tag >> 2) + 1)
        default:
            var off = 0
            for k in 0..<4 { off |= try byte() << (8 * k) }
            try copy(off, (tag >> 2) + 1)
        }
    }
    guard out.count == length else { throw ASRError("snappy 长度不符") }
    return Data(out)
}

// MARK: - secp128r1（系统库不带此曲线，手写）

enum Secp128r1 {
    typealias Point = (x: UInt128, y: UInt128)?

    static let p: UInt128 = 0xFFFF_FFFD_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF
    static let a: UInt128 = 0xFFFF_FFFD_FFFF_FFFF_FFFF_FFFF_FFFF_FFFC
    static let n: UInt128 = 0xFFFF_FFFE_0000_0000_75A3_0D1B_9038_A115
    static let g: Point = (0x161F_F752_8B89_9B2D_0C28_607C_A52C_5B86, 0xCF5A_C839_5BAF_EB13_C02D_A292_DDED_7A83)

    /// p = 2^128 - 2^97 - 1，故 2^128 ≡ 2^97 + 1
    private static func mul(_ x: UInt128, _ y: UInt128) -> UInt128 {
        var (hi, lo) = x.multipliedFullWidth(by: y)
        let fold: UInt128 = (1 << 97) + 1
        while hi != 0 {
            let (h2, l2) = hi.multipliedFullWidth(by: fold)
            let (s, carry) = lo.addingReportingOverflow(l2)
            lo = s
            hi = h2 + (carry ? 1 : 0)
        }
        while lo >= p { lo -= p }
        return lo
    }

    private static func add(_ x: UInt128, _ y: UInt128) -> UInt128 {
        let (s, o) = x.addingReportingOverflow(y)
        return o || s >= p ? s &- p : s
    }

    private static func sub(_ x: UInt128, _ y: UInt128) -> UInt128 { x >= y ? x - y : x &+ (p &- y) }

    private static func inverse(_ x: UInt128) -> UInt128 {
        var result: UInt128 = 1, base = x % p, e = p - 2
        while e > 0 {
            if e & 1 == 1 { result = mul(result, base) }
            base = mul(base, base)
            e >>= 1
        }
        return result
    }

    private static func addPoints(_ p1: Point, _ p2: Point) -> Point {
        guard let (x1, y1) = p1 else { return p2 }
        guard let (x2, y2) = p2 else { return p1 }
        if x1 == x2, add(y1, y2) == 0 { return nil }
        let slope = x1 == x2 && y1 == y2
            ? mul(add(mul(3, mul(x1, x1)), a), inverse(mul(2, y1)))
            : mul(sub(y2, y1), inverse(sub(x2, x1)))
        let x3 = sub(sub(mul(slope, slope), x1), x2)
        return (x3, sub(mul(slope, sub(x1, x3)), y1))
    }

    private static func multiply(_ k: UInt128, _ point: Point) -> Point {
        var result: Point = nil, addend = point, k = k
        while k > 0 {
            if k & 1 == 1 { result = addPoints(result, addend) }
            addend = addPoints(addend, addend)
            k >>= 1
        }
        return result
    }

    private static func hex(_ v: UInt128) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: 32 - s.count) + s
    }

    static func generateKeyPair() -> (UInt128, String) {
        while true {
            let k = UInt128.random(in: 1..<n)
            if let (x, y) = multiply(k, g) { return (k, "04" + hex(x) + hex(y)) }
        }
    }

    /// 共享点 x 坐标的大写 hex（32 字符，直接作 AES-256 密钥）
    static func sharedX(_ priv: UInt128, _ publicHex: String) throws -> String {
        guard publicHex.count == 66, publicHex.hasPrefix("04"),
              let x = UInt128(publicHex.dropFirst(2).prefix(32), radix: 16),
              let y = UInt128(publicHex.suffix(32), radix: 16),
              let (sx, _) = multiply(priv, (x, y)) else { throw ASRError("微信服务端公钥无效") }
        return hex(sx)
    }
}
