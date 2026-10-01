import Foundation

/// 豆包输入法流式识别：asr.AsrRequest protobuf over WSS，Opus 20ms 帧
final class DoubaoEngine: ASREngine {
    private static let wsURL = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws"
    private static let ua = "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"
    private static let ok = 20_000_000
    private static let first: UInt64 = 1, middle: UInt64 = 3, last: UInt64 = 9

    func run(audio: AsyncStream<[Int16]>, partial: @escaping (String) -> Void) async throws -> String {
        let device = try await DoubaoDevice.load()
        let rid = UUID().uuidString.lowercased()
        var request = URLRequest(url: URL(string: "\(Self.wsURL)?aid=401734&device_id=\(device.did)")!)
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("v2", forHTTPHeaderField: "proto-version")
        request.setValue("true", forHTTPHeaderField: "x-custom-keepalive")
        let ws = WebSocket(request: request)
        defer { ws.close() }

        do {
            try await ws.send(Self.request(token: device.token, method: "StartTask", rid: rid))
            try await Self.expect(ws, "TaskStarted")
            try await ws.send(Self.request(token: device.token, method: "StartSession",
                                           payload: Self.sessionConfig(did: device.did), rid: rid))
            try await Self.expect(ws, "SessionStarted")
        } catch let error as ASRError {
            DoubaoDevice.reset()
            throw error
        }

        let transcript = Transcript(partial: partial)
        let receiver = Task { try await Self.receiveResults(ws, into: transcript) }
        defer { receiver.cancel() }

        let encoder = try Opus(application: Opus.voip, bitrate: 16000, complexity: 5)
        let ts0 = Int(Date().timeIntervalSince1970 * 1000)
        var index = 0
        let meta = { (i: Int) in "{\"extra\":{},\"timestamp_ms\":\(ts0 + i * 20)}" }
        for await frame in audio {
            try Task.checkCancellation()
            try await ws.send(Self.request(method: "TaskRequest", payload: meta(index),
                                           audio: try encoder.encode(frame), rid: rid,
                                           frame: index == 0 ? Self.first : Self.middle))
            index += 1
        }
        try await ws.send(Self.request(method: "TaskRequest", payload: meta(index), rid: rid, frame: Self.last))
        try await ws.send(Self.request(token: device.token, method: "FinishSession", rid: rid))
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10 + Double(index) / 200))
            ws.close()
        }
        defer { watchdog.cancel() }
        do {
            try await receiver.value
        } catch {
            if transcript.result.isEmpty { throw error }
        }
        return transcript.result
    }

    private static func request(token: String = "", method: String, payload: String = "",
                                audio: Data = Data(), rid: String, frame: UInt64 = 0) -> Data {
        let pb = PBuf()
        if !token.isEmpty { pb.s(2, token) }
        pb.s(3, "ASR").s(5, method)
        if !payload.isEmpty { pb.s(6, payload) }
        if !audio.isEmpty { pb.s(7, audio) }
        pb.s(8, rid)
        if frame != 0 { pb.v(9, frame) }
        return pb.data
    }

    private struct Response {
        var event = "", status = 0, message = "", result = ""
        init(_ data: Data) throws {
            let f = try pbParse(data)
            event = f.string(4) ?? ""
            status = Int(Int32(truncatingIfNeeded: f.varint(5) ?? 0))
            message = f.string(6) ?? ""
            result = f.string(7) ?? ""
        }
    }

    private static func expect(_ ws: WebSocket, _ event: String) async throws {
        while true {
            let r = try Response(await ws.receive(timeout: 10))
            if r.event.hasSuffix("Failed") || (r.event == event && r.status != ok) {
                throw ASRError("豆包 \(r.event) \(r.status): \(r.message)")
            }
            if r.event == event { return }
        }
    }

    private static func receiveResults(_ ws: WebSocket, into transcript: Transcript) async throws {
        while true {
            // 静音期间上游不回包，超时只兜底；结束阶段由 watchdog 限时
            let r = try Response(await ws.receive(timeout: 600))
            if !r.result.isEmpty { transcript.update(r.result) }
            if r.event.hasSuffix("Failed") { throw ASRError("豆包 \(r.event) \(r.status): \(r.message)") }
            if r.event == "SessionFinished" { return }
        }
    }

    private static func sessionConfig(did: String) -> String {
        let cfg: [String: Any] = [
            "audio_info": ["channel": 1, "format": "speech_opus", "sample_rate": 16000],
            "enable_punctuation": true,
            "enable_speech_rejection": true,
            "extra": ["app_name": "oime", "cell_compress_rate": 8, "did": did,
                      "enable_asr_threepass": true, "enable_asr_twopass": true, "input_mode": "stream"],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: cfg), as: UTF8.self)
    }

    /// 上游按句定稿（index 递增，同一句可能再次定稿按 index 覆盖）；展示 = 已定稿句 + 当前句
    private final class Transcript {
        private var sentences: [Int: String] = [:]
        private var current = ""
        private var nextIndex = 0
        private let partial: (String) -> Void
        private let lock = NSLock()

        init(partial: @escaping (String) -> Void) { self.partial = partial }

        var result: String {
            lock.withLock {
                let done = sentences.keys.sorted().compactMap { sentences[$0] }
                return joinSentences(done.isEmpty ? [current] : done)
            }
        }

        func update(_ json: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else { return }
            let text: String = lock.withLock {
                for r in results {
                    guard let t = r["text"] as? String, !t.isEmpty else { continue }
                    let extra = r["extra"] as? [String: Any]
                    let isFinal = (extra?["nonstream_result"] as? Bool ?? false)
                        || (r["is_interim"] as? Bool == false && r["is_vad_finished"] as? Bool == true)
                    if isFinal {
                        let idx = r["index"] as? Int ?? nextIndex
                        sentences[idx] = t
                        nextIndex = max(nextIndex, idx + 1)
                        current = ""
                    } else {
                        current = t
                    }
                }
                return joinSentences(sentences.keys.sorted().compactMap { sentences[$0] } + [current])
            }
            partial(text)
        }
    }
}

/// 两侧都不是中日韩字符时补空格
func joinSentences(_ parts: [String]) -> String {
    func cjk(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
    var out = ""
    for t in parts where !t.isEmpty {
        if let a = out.last, let b = t.first, !cjk(a), !cjk(b) { out += " " }
        out += t
    }
    return out
}

/// 设备注册 + settings 拉取 asr app_key，本地缓存复用
struct DoubaoDevice: Codable {
    let did: String
    let token: String

    private static let file = appSupportFile("doubao.json")
    private static let ua = "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"
    private static let app: [String: String] = [
        "aid": "401734", "app_name": "oime", "channel": "official",
        "version_code": "100102018", "version_name": "1.1.2",
        "manifest_version_code": "100102018", "update_version_code": "100102018",
        "package": "com.bytedance.android.doubaoime",
    ]
    private static let dev: [String: String] = [
        "device_platform": "android", "os": "android", "os_api": "34", "os_version": "16",
        "device_type": "Pixel 7 Pro", "device_brand": "google", "device_model": "Pixel 7 Pro",
        "resolution": "1080*2400", "dpi": "420", "language": "zh", "timezone": "8",
        "access": "wifi", "rom": "UP1A.231005.007", "rom_version": "UP1A.231005.007",
    ]

    static func load() async throws -> DoubaoDevice {
        if let data = try? Data(contentsOf: file), let d = try? JSONDecoder().decode(DoubaoDevice.self, from: data) {
            return d
        }
        let d = try await register()
        try? JSONEncoder().encode(d).write(to: file)
        return d
    }

    static func reset() { try? FileManager.default.removeItem(at: file) }

    private static func post(_ base: String, query: [String: String], body: Data, contentType: String,
                             extra: [String: String] = [:]) async throws -> [String: Any] {
        var comps = URLComponents(string: base)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (k, v) in extra { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ASRError("豆包设备注册 HTTP 失败") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func register() async throws -> DoubaoDevice {
        let cdid = UUID().uuidString.lowercased()
        let now = String(Int(Date().timeIntervalSince1970 * 1000))
        var header: [String: Any] = dev.merging(app) { a, _ in a }
        header.merge([
            "device_id": 0, "install_id": 0, "cdid": cdid,
            "openudid": String(format: "%08x", UInt32.random(in: 0...UInt32.max)),
            "clientudid": UUID().uuidString.lowercased(),
            "region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28800,
            "sim_region": "cn", "carrier_region": "cn", "cpu_abi": "arm64-v8a", "build_serial": "unknown",
            "not_request_sender": 0, "sig_hash": "", "google_aid": "", "mc": "", "serial_number": "",
        ]) { _, b in b }
        let body = try JSONSerialization.data(withJSONObject: [
            "magic_tag": "ss_app_log", "header": header, "_gen_time": Int(now)!,
        ] as [String: Any])
        let reg = try await post("https://log.snssdk.com/service/2/device_register/",
                                 query: dev.merging(app) { a, _ in a }.merging(["ssmix": "a", "_rticket": now, "cdid": cdid, "ac": "wifi"]) { _, b in b },
                                 body: body, contentType: "application/json")
        let did = (reg["device_id_str"] as? String) ?? (reg["device_id"] as? NSNumber)?.stringValue ?? ""
        guard !did.isEmpty, did != "0" else { throw ASRError("豆包设备注册被拒绝") }

        let settings = try await post("https://is.snssdk.com/service/settings/v3/",
                                      query: app.merging(["device_platform": "android", "os": "android", "ssmix": "a",
                                                          "_rticket": now, "cdid": cdid, "device_id": did]) { _, b in b },
                                      body: Data("body=null".utf8), contentType: "application/x-www-form-urlencoded",
                                      extra: ["x-ss-stub": "46c03b52742b3f2615a3abdf1636b754"])
        let token = ((((settings["data"] as? [String: Any])?["settings"] as? [String: Any])?["asr_config"]
            as? [String: Any])?["app_key"] as? String) ?? ""
        guard !token.isEmpty else { throw ASRError("豆包 settings 未返回 app_key") }
        return DoubaoDevice(did: did, token: token)
    }
}
