import XCTest

final class ProtocolTests: XCTestCase {
    func testAggregateJoinsSegmentsAndDropsFailedText() {
        var a = Segment(text: "明天开会，", state: .final, stoppedAt: 10, doneAt: 10.5)
        let b = Segment(text: "带上报表", state: .listening)
        var r = Segment.aggregate([a, b])
        XCTAssertEqual(r.text, "明天开会，带上报表")
        XCTAssertEqual(r.state, .listening)
        XCTAssertNil(r.ms)

        a.state = .error
        a.error = "网络不可用"
        r = Segment.aggregate([a, Segment(text: "带上报表", state: .final, stoppedAt: 20, doneAt: 20.64)])
        XCTAssertEqual(r.text, "带上报表")
        XCTAssertEqual(r.state, .error)
        XCTAssertEqual(r.error, "网络不可用")
        XCTAssertEqual(r.ms, 640)
    }

    func testAggregateFinalizingWinsOverError() {
        let r = Segment.aggregate([Segment(state: .error), Segment(text: "x", state: .finalizing, stoppedAt: 1)])
        XCTAssertEqual(r.state, .finalizing)
        XCTAssertNil(r.error)
    }

    func testSilenceDetectorWaitsForSpeechThenHold() {
        var d = SilenceDetector(hold: 1.5)
        for _ in 0..<200 { XCTAssertFalse(d.feed(rms: 0.002, duration: 0.02)) }
        XCTAssertFalse(d.heard)
        for _ in 0..<25 { XCTAssertFalse(d.feed(rms: 0.08, duration: 0.02)) }
        XCTAssertTrue(d.heard)
        var stopped = 0.0
        for i in 1...100 where d.feed(rms: 0.004, duration: 0.02) {
            stopped = Double(i) * 0.02
            break
        }
        XCTAssertEqual(stopped, 1.5, accuracy: 0.021)
    }

    func testSilenceDetectorSpeechResetsQuiet() {
        var d = SilenceDetector(hold: 1.5)
        _ = d.feed(rms: 0.1, duration: 0.02)
        for _ in 0..<70 { XCTAssertFalse(d.feed(rms: 0.003, duration: 0.02)) }
        _ = d.feed(rms: 0.1, duration: 0.02)
        for _ in 0..<70 { XCTAssertFalse(d.feed(rms: 0.003, duration: 0.02)) }
    }

    func testIdleExpiry() {
        XCTAssertNil(Idle.expiry(lastActivity: 100, seconds: 0, busy: false, now: 200))
        XCTAssertEqual(Idle.expiry(lastActivity: 100, seconds: 600, busy: false, now: 200), 700)
        XCTAssertEqual(Idle.expiry(lastActivity: 100, seconds: 600, busy: true, now: 200), 800)
    }

    func testConfigChannelResolution() {
        var c = Config.initial
        XCTAssertEqual(c.channels.map { $0.name }, ["微信", "千问", "讯飞", "百度"])
        XCTAssertEqual(c.active.map(\.engine), ["wetype"])
        XCTAssertFalse(c.isMulti)
        c.channels[1].on = true
        XCTAssertTrue(c.isMulti)
        XCTAssertEqual(c.active.map(\.id), ["a", "b"])
        c.multi = false
        c.defaultChannel = "b"
        XCTAssertEqual(c.active.map(\.id), ["b"])
        XCTAssertEqual(c.resolve(["c", "a"]).map(\.id), ["a"])
        XCTAssertEqual(c.resolve([]).map(\.id), ["b"])
        XCTAssertFalse(c.channels.contains { $0.engine == "doubao" })
    }

    func testConfigMigratesLegacyDefaultNames() {
        var old = Config.initial
        old.channels[0].name = "渠道 A"
        old.channels[1].name = "我的千问"
        old.channels[2].name = "渠道 C"
        old.channels[2].on = true
        let c = old.migrated()
        XCTAssertEqual(c.channels.map { $0.name }, ["微信", "我的千问", "讯飞", "百度"])
        XCTAssertEqual(c.channels.map { $0.on }, [true, false, true, false])
        let h = try! JSONDecoder().decode([HistoryItem].self, from: Data(#"[{"text":"x","channel":"渠道 D","at":1},{"text":"y","channel":"我的","at":2}]"#.utf8))
        XCTAssertEqual(h.map(\.channel), ["百度", "我的"])
    }

    func testCommandQueueOrdersPending() {
        let q = CommandQueue(cmds: [
            Command(seq: 7, at: 0, op: .stop, utt: 2),
            Command(seq: 5, at: 0, op: .start),
            Command(seq: 6, at: 0, op: .touch),
        ])
        XCTAssertEqual(q.pending(after: 5).map(\.seq), [6, 7])
        XCTAssertEqual(q.maxSeq, 7)
    }

    func testWireFormat() throws {
        let s = LiveState(
            launch: "L", updatedAt: 1, ackSeq: 3,
            session: .init(active: true, since: 0, expiresAt: 600, idleMinutes: 10, interrupted: false),
            utterance: .init(id: 1, startSeq: 3, phase: .recording, silenceStop: 1.5, level: 0.2,
                             rows: [.init(channel: "a", name: "微信", text: "你好", state: .listening)], retryable: true))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        XCTAssertEqual(json["v"] as? Int, 1)
        let u = json["utterance"] as! [String: Any]
        XCTAssertEqual(u["phase"] as? String, "recording")
        XCTAssertEqual((u["rows"] as! [[String: Any]])[0]["state"] as? String, "listening")
        XCTAssertEqual(try JSONDecoder().decode(LiveState.self, from: JSONEncoder().encode(s)), s)

        let c = try JSONDecoder().decode(Command.self, from: Data(#"{"seq":4,"at":1,"op":"continue","utt":1}"#.utf8))
        XCTAssertEqual(c.op, .continue)
    }
}
