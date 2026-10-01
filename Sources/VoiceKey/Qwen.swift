import CommonCrypto
import CryptoKit
import Foundation
import Network

/// 千问输入法 ASR：独立 WSG（HMAC-SHA1 + AES-128-CBC），不依赖本机 IME。
/// WSS：HTTP/1.1 101 后发 protobuf 二进制帧（attach → asr/send PCM → complete）。
final class QwenEngine: ASREngine {
    static let ve = "1.2.35.46"
    static let origin = "https://www.qianwen.com"
    static let hmacKey = Data("2d473b000fdb53e617446f805d4eaaacbb324bd16ee9f6d8237abd0ab79c5e48".utf8)
    static let aesKey = Data("a0a6237b2b735a54".utf8)
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 TONGYI_DESKTOP/0.1.0 QuarkPC/ime_voice"

    private var client: Session?

    func prewarm() {
        Task { _ = try? await channel(fresh: false) }
    }

    private func channel(fresh: Bool) async throws -> (Session, reused: Bool) {
        if !fresh, let c = client, c.alive { return (c, true) }
        client?.close()
        client = nil
        do {
            let c = try await Session.open()
            client = c
            return (c, false)
        } catch {
            QwenDevice.reset()
            throw error
        }
    }

    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        var (c, reused) = try await channel(fresh: false)
        do {
            try await c.ensureAttach()
        } catch {
            guard reused else { throw error }
            c.close()
            if client === c { client = nil }
            (c, _) = try await channel(fresh: true)
            try await c.ensureAttach()
        }

        if QwenOutput.current == .translate {
            try await c.updateTranslation()
        }

        let transcript = Box(partial: partial)
        let receiver = Task {
            while !Task.isCancelled {
                guard let data = try await c.ws.receiveOrNil(timeout: 8) else { continue }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if ProcessInfo.processInfo.environment["QWEN_DEBUG"] != nil,
                       let s = String(data: data, encoding: .utf8) {
                        fputs("QWEN_DOWN \(s.prefix(800))\n", stderr)
                    }
                    if let d = obj["data"] as? [String: Any],
                       let s = d["sessionId"] as? String, !s.isEmpty {
                        if obj["route"] as? String == "/voice_assistant/channel/attach" {
                        c.noteSession(s, round: d["roundId"] as? String)
                        }
                        if let nr = d["newRoundId"] as? String, !nr.isEmpty {
                            c.noteRound(nr)
                        }
                    }
                    Self.ingest(obj, into: transcript)
                }
            }
        }
        defer { receiver.cancel() }

        do {
            var pcm = Data()
            for await frame in audio {
                try Task.checkCancellation()
                pcm.append(contentsOf: frame.withUnsafeBufferPointer { Data(buffer: $0) })
                while pcm.count >= 3840 {
                    let chunk = Data(pcm.prefix(3840))
                    pcm = Data(pcm.dropFirst(3840))
                    try await c.sendAudio(chunk)
                }
            }
            if !pcm.isEmpty {
                if pcm.count < 3840 { pcm.append(Data(repeating: 0, count: 3840 - pcm.count)) }
                try await c.sendAudio(Data(pcm.prefix(3840)))
            }
            try await c.complete()
            let waitN = QwenOutput.current == .translate ? 16 : 8
            for _ in 0..<waitN where transcript.waiting {
                try await Task.sleep(for: .milliseconds(250))
            }
            c.reset()
            if transcript.result.isEmpty { throw ASRError("千问没有识别文本") }
            return transcript.result
        } catch {
            c.close()
            if client === c { client = nil }
            throw error
        }
    }

    fileprivate final class Session {
        let auth: QwenAuth
        let ws: QwenRawWS
        private var sessionId = ""
        private var roundId = ""
        private var attached = false
        private var output = QwenOutput.current
        var alive: Bool { ws.alive }

        init(auth: QwenAuth, ws: QwenRawWS) {
            self.auth = auth
            self.ws = ws
        }

        static func open() async throws -> Session {
            let auth = try QwenAuth.make()
            return Session(auth: auth, ws: try await QwenRawWS.connect(auth: auth))
        }

        func ensureAttach() async throws {
            let output = QwenOutput.current
            if attached, !sessionId.isEmpty, self.output == output { return }
            self.output = output
            try await ws.send(binary: QwenEngine.attach(auth: auth))
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, sessionId.isEmpty {
                guard let data = try await ws.receiveOrNil(timeout: 2) else { continue }
                if ProcessInfo.processInfo.environment["QWEN_DEBUG"] != nil,
                   let s = String(data: data, encoding: .utf8) {
                    fputs("QWEN_ATTACH \(s.prefix(1200))\n", stderr)
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let d = obj["data"] as? [String: Any],
                      let s = d["sessionId"] as? String, !s.isEmpty else { continue }
                sessionId = s
                roundId = (d["roundId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ro_\(s)_0"
            }
            guard !sessionId.isEmpty else { throw ASRError("千问 attach 没有 sessionId") }
            attached = true
        }

        func updateTranslation() async throws {
            try await ws.send(binary: QwenEngine.transform(auth: auth, sessionId: sessionId, roundId: roundId))
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                guard let data = try await ws.receiveOrNil(timeout: 1) else { continue }
                if ProcessInfo.processInfo.environment["QWEN_DEBUG"] != nil,
                   let s = String(data: data, encoding: .utf8) {
                    fputs("QWEN_TRANSFORM \(s.prefix(800))\n", stderr)
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if obj["route"] as? String == "/voice_assistant/channel/transform" {
                    let d = obj["data"] as? [String: Any]
                    if d?["accepted"] as? Bool == true { return }
                    let reason = d?["reason"] as? String ?? obj["msg"] as? String ?? "rejected"
                    throw ASRError("千问 transform 拒绝: \(reason)")
                }
            }
            throw ASRError("千问 transform 无响应")
        }

        func sendAudio(_ pcm: Data) async throws {
            try await ws.send(binary: QwenEngine.asrSend(auth: auth, sessionId: sessionId, roundId: roundId, pcm: pcm))
        }

        func complete() async throws {
            try await ws.send(binary: QwenEngine.asrComplete(auth: auth, sessionId: sessionId, roundId: roundId))
        }

        func noteSession(_ id: String, round: String?) {
            sessionId = id
            roundId = round.flatMap { $0.isEmpty ? nil : $0 } ?? "ro_\(id)_0"
            attached = true
        }
        func noteRound(_ id: String) { roundId = id }
        func reset() {
            attached = false
            sessionId = ""
            roundId = ""
        }

        func sendText(_ text: String) async throws {
            if ProcessInfo.processInfo.environment["QWEN_DEBUG"] != nil {
                fputs("QWEN_TEXT_SEND \(text.prefix(80))\n", stderr)
            }
            try await ws.send(binary: QwenEngine.textSend(auth: auth, sessionId: sessionId, roundId: roundId, text: text))
        }
        func completeText() async throws {
            try await ws.send(binary: QwenEngine.textComplete(auth: auth, sessionId: sessionId, roundId: roundId))
        }

        func close() { ws.close() }
    }

    private enum QwenPB {
        static func varint(_ n: Int) -> Data {
            var n = n, d = Data()
            while n > 0x7f { d.append(UInt8((n & 0x7f) | 0x80)); n >>= 7 }
            d.append(UInt8(n)); return d
        }
        static func bytes(_ fn: Int, _ s: String) -> Data { bytes(fn, Data(s.utf8)) }
        static func bytes(_ fn: Int, _ b: Data) -> Data { varint((fn << 3) | 2) + varint(b.count) + b }
        static func kv(_ fn: Int, _ k: String, _ v: String) -> Data { bytes(fn, bytes(1, k) + bytes(2, v)) }
    }

    private static func nowMs() -> String { String(Int(Date().timeIntervalSince1970 * 1000)) }
    private static func attach(auth: QwenAuth) throws -> Data {
        let reqt = nowMs()
        let output = QwenOutput.current
        var header: [String: Any] = [
            "clt-acs-reqt": reqt,
            "ai_polish_mode": output == .asr ? "off" : "smart",
        ]
        let asr: [String: Any] = [
            "body": [
                "bitDepth": "16", "channel": "mono", "format": "pcm",
                "maxEndSilence": "180000", "maxStartSilence": "180000",
                "sampleRate": "16000", "type": "manualStreamStop",
            ],
            "chid": auth.chid,
            "header": header,
            "param": [:] as [String: Any],
            "route": "/app/live/init",
        ]
        let pipe: [String: Any] = [
            "biz_data": [:] as [String: Any],
            "biz_id": "ai_command",
            "chat_client": "native",
            "client_tm": reqt,
            "endpoint_config": [:] as [String: Any],
            "from": "kkframenew_quark_asr",
            "scene": "voice_input_assistant",
            "ai_polish_mode": output == .asr ? "off" : "smart",
        ]
        let asrJSON = String(data: try JSONSerialization.data(withJSONObject: asr), encoding: .utf8)!
        let pipeJSON = String(data: try JSONSerialization.data(withJSONObject: pipe), encoding: .utf8)!
        return QwenPB.bytes(1, "/voice_assistant/channel/attach")
            + QwenPB.bytes(2, auth.chid)
            + QwenPB.kv(3, "clt-acs-reqt", reqt)
            + QwenPB.kv(5, "asrConfig", asrJSON)
            + QwenPB.kv(5, "pipelineContext", pipeJSON)
            + QwenPB.kv(5, "trigger", "local_device")
    }
    private static func textSend(auth: QwenAuth, sessionId: String, roundId: String, text: String) -> Data {
        let body = QwenPB.bytes(1, "text") + QwenPB.bytes(2, "plain") + QwenPB.bytes(3, Data(text.utf8))
        return QwenPB.bytes(1, "/voice_assistant/channel/text/send")
            + QwenPB.bytes(2, auth.chid)
            + QwenPB.kv(3, "clt-acs-reqt", nowMs())
            + QwenPB.kv(4, "roundId", roundId)
            + QwenPB.kv(4, "sessionId", sessionId)
            + QwenPB.kv(5, "target_language", "en")
            + QwenPB.kv(5, "current_text", text)
            + QwenPB.bytes(6, body)
    }
    private static func textComplete(auth: QwenAuth, sessionId: String, roundId: String) -> Data {
        QwenPB.bytes(1, "/voice_assistant/channel/text/complete")
            + QwenPB.bytes(2, auth.chid)
            + QwenPB.kv(3, "clt-acs-reqt", nowMs())
            + QwenPB.kv(4, "roundId", roundId)
            + QwenPB.kv(4, "sessionId", sessionId)
            + QwenPB.kv(5, "target_language", "en")
    }
    private static func transform(auth: QwenAuth, sessionId: String, roundId: String) -> Data {
        var pkt = QwenPB.bytes(1, "/voice_assistant/channel/transform")
        pkt += QwenPB.bytes(2, auth.chid)
        pkt += QwenPB.kv(3, "clt-acs-reqt", nowMs())
        pkt += QwenPB.kv(4, "roundId", roundId)
        pkt += QwenPB.kv(4, "sessionId", sessionId)
        pkt += QwenPB.kv(4, "target_sub_scene", "VOICE_INPUT_TRANSLATE")
        pkt += QwenPB.kv(4, "target_language", "en")
        pkt += QwenPB.kv(4, "source_language", "zh")
        return pkt
    }
    private static func asrSend(auth: QwenAuth, sessionId: String, roundId: String, pcm: Data) -> Data {
        let audio = QwenPB.bytes(1, "audio") + QwenPB.bytes(2, "pcm") + QwenPB.bytes(3, pcm)
        return QwenPB.bytes(1, "/voice_assistant/channel/asr/send")
            + QwenPB.bytes(2, auth.chid)
            + QwenPB.kv(3, "clt-acs-reqt", nowMs())
            + QwenPB.kv(4, "roundId", roundId)
            + QwenPB.kv(4, "sessionId", sessionId)
            + QwenPB.kv(5, "streamInputState", "process")
            + QwenPB.bytes(6, audio)
    }

    private static func asrComplete(auth: QwenAuth, sessionId: String, roundId: String) -> Data {
        QwenPB.bytes(1, "/voice_assistant/channel/asr/complete")
            + QwenPB.bytes(2, auth.chid)
            + QwenPB.kv(3, "clt-acs-reqt", nowMs())
            + QwenPB.kv(4, "roundId", roundId)
            + QwenPB.kv(4, "sessionId", sessionId)
    }

    private final class Box {
        private let lock = NSLock()
        private let partial: (String) -> Void
        private var asr = ""
        private(set) var polish = ""
        private var translate = ""
        private let mode = QwenOutput.current
        init(partial: @escaping (String) -> Void) { self.partial = partial }
        var result: String {
            lock.withLock {
                switch mode {
                case .asr: asr
                case .polish: polish.isEmpty ? asr : polish
                case .translate: translate.isEmpty ? (polish.isEmpty ? asr : polish) : translate
                }
            }
        }
        var waiting: Bool {
            lock.withLock {
                switch mode {
                case .asr: false
                case .polish: polish.isEmpty
                case .translate: translate.isEmpty
                }
            }
        }
        var asrText: String { lock.withLock { asr } }
        var translateEmpty: Bool { lock.withLock { translate.isEmpty } }
        func setASR(_ s: String) {
            lock.lock(); asr = s; let p = partial; lock.unlock(); p(s)
        }
        func setPolish(_ s: String) {
            lock.lock(); polish = s; let p = partial; lock.unlock(); p(s)
        }
        func setTranslate(_ s: String) {
            lock.lock(); translate = s; let p = partial; lock.unlock(); p(s)
        }
    }

    private static func ingest(_ obj: [String: Any], into t: Box) {
        walk(obj, into: t)
    }

    private static func walk(_ any: Any, into t: Box) {
        if let d = any as? [String: Any] {
            if let text = (d["content"] as? [String: Any])?["text"] as? String, !text.isEmpty {
                t.setASR(text)
            }
            if let messages = d["messages"] as? [[String: Any]] {
                for m in messages {
                    if let s = m["content"] as? String, !s.isEmpty { t.setPolish(s) }
                }
            }
            for (k, v) in d {
                if (k == "translatedText" || k == "translated_text"),
                   let s = v as? String, !s.isEmpty {
                    t.setTranslate(s)
                } else {
                    walk(v, into: t)
                }
            }
        } else if let a = any as? [Any] {
            for v in a { walk(v, into: t) }
        }
    }
}

/// 本机 UTDID 只生成一次，落到 Application Support，会话 chid 仍每次新开。
struct QwenDevice: Codable {
    let utdid: String
    private static let file = appSupportFile("qwen.json")

    static func load() throws -> QwenDevice {
        if let data = try? Data(contentsOf: file),
           let d = try? JSONDecoder().decode(QwenDevice.self, from: data),
           !d.utdid.isEmpty {
            return d
        }
        let d = QwenDevice(utdid: "VK" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))
        try? JSONEncoder().encode(d).write(to: file)
        return d
    }

    static func reset() { try? FileManager.default.removeItem(at: file) }
}

struct QwenAuth {
    let utdid: String
    let ut: String
    let chid: String
    let reqt: String
    let sign: String

    static func make() throws -> QwenAuth {
        let utdid = try QwenDevice.load().utdid
        let ut = try encrypt(Array(utdid.utf8))
        let chid = UUID().uuidString.lowercased() + "_1"
        let reqt = String(Int(Date().timeIntervalSince1970 * 1000))
        let input = ut + QwenEngine.ve + chid + reqt
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(input.utf8), using: SymmetricKey(data: QwenEngine.hmacKey))
        let sign = "4ea4" + mac.map { String(format: "%02x", $0) }.joined()
        return QwenAuth(utdid: String(utdid), ut: ut, chid: chid, reqt: reqt, sign: sign)
    }

    var headers: [String: String] {
        [
            "clt-acs-ut": Self.qenc(ut),
            "clt-acs-ve": QwenEngine.ve,
            "clt-acs-kp": "",
            "clt-acs-reqt": reqt,
            "clt-acs-wsgnver": "1",
            "clt-acs-request-params": "chid",
            "clt-acs-sign": sign,
            "clt-acs-caer": "tlbe",
            "x-wpk-reqid": chid,
        ]
    }

    var query: String {
        let utq = Self.qenc(ut)
        return "chid=\(chid)&biz_id=ai_qwen_input&from=kkframenew_quark_asr&uc_param_str=vepffrprsvchut&ut=\(utq)&ve=\(QwenEngine.ve)&pf=8002&pr=qwen&fr=mac&sv=release&ch=qianwen-ime"
    }

    static func qenc(_ s: String) -> String {
        var a = CharacterSet.alphanumerics
        a.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: a) ?? s
    }

    var wsURL: URL { URL(string: "wss://voice-input.qianwen.com/ws/v1/voice?\(query)")! }

    func preference() async throws {
        var req = URLRequest(url: URL(string: "https://voice-input.qianwen.com/api/voice/input/preference/getPreference?\(query)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(QwenEngine.ua, forHTTPHeaderField: "User-Agent")
        req.setValue(QwenEngine.origin, forHTTPHeaderField: "Origin")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ASRError("千问 preference HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["code"] as? String == "00000" else {
            throw ASRError("千问签名校验失败：\(String(data: data, encoding: .utf8) ?? "")")
        }
    }

    private static func encrypt(_ plain: [UInt8]) throws -> String {
        var out = [UInt8](repeating: 0, count: plain.count + 32)
        var n = out.count
        let key = [UInt8](QwenEngine.aesKey)
        let rc = key.withUnsafeBytes { kb in
            plain.withUnsafeBytes { pb in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        kb.baseAddress, key.count, kb.baseAddress,
                        pb.baseAddress, plain.count, &out, out.count, &n)
            }
        }
        guard rc == kCCSuccess else { throw ASRError("千问 AES 失败 \(rc)") }
        var packed: [UInt8] = [0x4e, 0xa4]
        packed.append(contentsOf: out[0..<n])
        return Data(packed).base64EncodedString()
    }
}

/// 裸 TLS + HTTP/1.1 Upgrade。URLSession 会走 h2，Tengine 回 200。
final class QwenRawWS {
    private let conn: NWConnection
    private var buf = Data()
    private let q = DispatchQueue(label: "qwen.ws")
    private var dead = false
    var alive: Bool { !dead }

    init(conn: NWConnection) { self.conn = conn }

    static func connect(auth: QwenAuth) async throws -> QwenRawWS {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        let params = NWParameters(tls: tls, tcp: tcp)
        params.preferNoProxies = true
        let conn = NWConnection(host: "voice-input.qianwen.com", port: 443, using: params)
        let q = DispatchQueue(label: "qwen.nw")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var done = false
            func once(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; if done { return }; done = true; body() }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: once { c.resume() }
                case .failed(let e): once { c.resume(throwing: e) }
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + 8) {
                once { conn.cancel(); c.resume(throwing: ASRError("千问 TLS 连接超时")) }
            }
        }
        let ws = QwenRawWS(conn: conn)
        ws.watch()
        try await ws.handshake(auth)
        return ws
    }

    private func handshake(_ auth: QwenAuth) async throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var lines = [
            "GET /ws/v1/voice?\(auth.query) HTTP/1.1",
            "Host: voice-input.qianwen.com",
            "Connection: Upgrade",
            "Cache-Control: no-cache",
            "User-Agent: \(QwenEngine.ua)",
            "Upgrade: websocket",
            "Origin: \(QwenEngine.origin)",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Key: \(key)",
        ]
        for (k, v) in auth.headers { lines.append("\(k): \(v)") }
        try await sendRaw(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
        var head = Data()
        let sep = Data("\r\n\r\n".utf8)
        while true {
            if let r = head.range(of: sep) {
                buf = Data(head[r.upperBound...])
                head = Data(head[..<r.upperBound])
                break
            }
            head.append(try await recvSome())
            if head.count > 8192 { throw ASRError("千问握手过长") }
        }
        let status = String(data: head.split(separator: 0x0a).first ?? head, encoding: .utf8) ?? ""
        guard status.contains("101") else { throw ASRError("千问 WSS \(status.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    func send(text: String) async throws {
        try await sendRaw(Self.frame(Data(text.utf8), opcode: 0x1))
    }

    func send(binary: Data) async throws {
        try await sendRaw(Self.frame(binary, opcode: 0x2))
    }

    func receive(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let f = try popFrame() { return f }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { break }
            buf.append(try await recvSome())
        }
        throw ASRError("服务器响应超时")
    }

    func receiveOrNil(timeout: TimeInterval) async throws -> Data? {
        do { return try await receive(timeout: timeout) }
        catch { return nil }
    }

    func close() { dead = true; conn.cancel() }

    private func watch() {
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.dead = true
            default: break
            }
        }
    }

    private func popFrame() throws -> Data? {
        let b = [UInt8](buf)
        guard b.count >= 2 else { return nil }
        let op = b[0] & 0x0f
        var n = Int(b[1] & 0x7f)
        var i = 2
        if n == 126 {
            guard b.count >= 4 else { return nil }
            n = Int(b[2]) << 8 | Int(b[3]); i = 4
        } else if n == 127 { return nil }
        guard b.count >= i + n else { return nil }
        let payload = Data(b[i..<(i + n)])
        buf = Data(b[(i + n)...])
        if op == 0x9 {
            let p = payload
            Task { try? await sendRaw(Self.frame(p, opcode: 0xA)) }
            return try popFrame()
        }
        if op == 0x8 { dead = true; throw ASRError("千问 WS 关闭") }
        if op == 0x1 || op == 0x2 { return payload }
        return try popFrame()
    }

    private func sendRaw(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: d, completion: .contentProcessed { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            })
        }
    }

    private func recvSome() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, err in
                if let err { c.resume(throwing: err); return }
                c.resume(returning: data ?? Data())
            }
        }
    }

    private static func frame(_ payload: Data, opcode: UInt8) -> Data {
        var mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        var out = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 { out.append(0x80 | UInt8(n)) }
        else if n < 65536 {
            out.append(0x80 | 126)
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xff))
        } else {
            out.append(0x80 | 127)
            for i in (0..<8).reversed() { out.append(UInt8((n >> (i * 8)) & 0xff)) }
        }
        out.append(contentsOf: mask)
        out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return out
    }
}
