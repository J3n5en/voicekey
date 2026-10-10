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
        XCTAssertNil(Idle.expiry(lastActivity: 100, seconds: 0, standby: .mic, busy: false, now: 200))
        XCTAssertEqual(Idle.expiry(lastActivity: 100, seconds: 600, standby: .mic, busy: false, now: 200), 700)
        XCTAssertEqual(Idle.expiry(lastActivity: 100, seconds: 600, standby: .mic, busy: true, now: 200), 800)
    }

    func testPipNeverExpiresEvenPastSavedIdleLimit() {
        for minutes in Config.idleChoices {
            for busy in [false, true] {
                for now in [200.0, 399, 400, 699, 700, 1900, 86400] {
                    XCTAssertNil(Idle.expiry(lastActivity: 100, seconds: Double(minutes * 60), standby: .pip, busy: busy, now: now))
                }
            }
        }
    }

    func testMicExpiresAtSavedIdleLimit() throws {
        for minutes in Config.idleChoices where minutes > 0 {
            let deadline = Double(100 + minutes * 60)
            for now in [deadline - 1, deadline, deadline + 1] {
                let expiry = try XCTUnwrap(Idle.expiry(lastActivity: 100, seconds: Double(minutes * 60), standby: .mic, busy: false, now: now))
                XCTAssertEqual(expiry <= now, now >= deadline)
            }
        }
    }

    func testSilenceSetting() throws {
        XCTAssertEqual(Config.initial.silenceSeconds, 1.5)
        var c = Config.initial
        c.silence = 3
        c = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(c.silenceSeconds, 3)
        c.silence = 9
        XCTAssertEqual(c.silenceSeconds, 5)
        let legacy = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(Config.initial))
        XCTAssertEqual(legacy.silenceSeconds, 1.5)
    }

    func testPipUpgradeAndModeSwitchPreserveSavedSettings() throws {
        for minutes in Config.idleChoices {
            var old = Config.initial
            old.idleMinutes = minutes
            old.channels[1].on = true
            old.channels[4].on = true
            old.multi = false
            old.defaultChannel = "b"
            old.lastPick = "e"
            var c = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(old)).migrated()
            XCTAssertEqual(c, old)
            for mode in [Standby.mic, .pip, .mic] {
                c.standby = mode
                c = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
                let expiry = Idle.expiry(lastActivity: 100, seconds: Double(c.idleMinutes * 60), standby: c.standbyMode, busy: false, now: 86400)
                XCTAssertEqual(expiry, mode == .mic && minutes > 0 ? Double(100 + minutes * 60) : nil)
                var expected = old
                expected.standby = mode
                XCTAssertEqual(c, expected)
            }
        }
    }

    func testLegacyPipDeadlineIgnoredForRecoveryAndKeyboard() throws {
        let json = #"{"active":true,"expiresAt":700,"idleMinutes":10,"interrupted":false,"standby":"pip"}"#
        var s = try JSONDecoder().decode(LiveState.Session.self, from: Data(json.utf8))
        XCTAssertNil(s.idleExpiry, "旧画中画倒计时不应触发恢复时过期或键盘提醒")
        XCTAssertTrue(s.micReady)
        s.standby = .mic
        XCTAssertEqual(s.idleExpiry, 700)
        s.standby = nil
        XCTAssertEqual(s.idleExpiry, 700, "v1 常开麦会话保留原到期时间")
    }

    func testConfigChannelResolution() {
        var c = Config.initial
        XCTAssertEqual(c.channels.map { $0.name }, ["微信", "千问", "讯飞", "百度", "豆包"])
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
        XCTAssertEqual(c.channels.last, Channel(id: "e", engine: "doubao", name: "豆包", on: false))
        XCTAssertTrue(c.resolve(["e"]).isEmpty)
        c.channels[4].on = true
        XCTAssertEqual(c.resolve(["e"]).map(\.engine), ["doubao"])
        c.defaultChannel = "e"
        XCTAssertEqual(c.active.map(\.engine), ["doubao"])
    }

    func testConfigMigratesLegacyDefaultNames() {
        var old = Config.initial
        old.channels[0].name = "渠道 A"
        old.channels[1].name = "我的千问"
        old.channels[2].name = "渠道 C"
        old.channels[2].on = true
        let c = old.migrated()
        XCTAssertEqual(c.channels.map { $0.name }, ["微信", "我的千问", "讯飞", "百度", "豆包"])
        XCTAssertEqual(c.channels.map { $0.on }, [true, false, true, false, false])
        let h = try! JSONDecoder().decode([HistoryItem].self, from: Data(#"[{"text":"x","channel":"渠道 D","at":1},{"text":"y","channel":"我的","at":2}]"#.utf8))
        XCTAssertEqual(h.map(\.channel), ["百度", "我的"])
    }

    func testConfigUpgradeAddsDisabledDoubaoWithoutChangingChoices() throws {
        let json = #"{"channels":[{"id":"a","engine":"wetype","name":"我的微信","on":false},{"id":"b","engine":"qwen","name":"千问","on":true},{"id":"c","engine":"iflytek","name":"讯飞","on":true},{"id":"d","engine":"baidu","name":"百度","on":false}],"multi":false,"defaultChannel":"c","idleMinutes":30,"lastPick":"b","standby":"mic"}"#
        let old = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let upgraded = old.migrated()
        var expected = old
        expected.channels.append(Channel(id: "e", engine: "doubao", name: "豆包", on: false))
        XCTAssertEqual(upgraded, expected)
        XCTAssertEqual(upgraded.active, old.active)
        XCTAssertEqual(upgraded.enabled, old.enabled)
        XCTAssertEqual(upgraded.migrated(), upgraded)
        let saved = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(upgraded))
        XCTAssertEqual(saved.migrated(), upgraded)
        XCTAssertEqual(Config.initial.migrated(), Config.initial)
    }

    func testConfigMigrationPreservesExistingDoubaoChoices() {
        for on in [false, true] {
            var old = Config.initial
            old.channels = [Channel(id: "custom", engine: "doubao", name: "我的豆包", on: on)]
            old.multi = false
            old.defaultChannel = "custom"
            old.lastPick = "custom"
            let upgraded = old.migrated()
            XCTAssertEqual(upgraded, old)
            XCTAssertEqual(upgraded.migrated(), old)
        }
        var old = Config.initial
        old.channels[4].on = true
        old.channels[4].name = "渠道 E"
        let upgraded = old.migrated()
        XCTAssertEqual(upgraded.channels[4].name, "豆包")
        XCTAssertTrue(upgraded.channels[4].on)
        XCTAssertEqual(upgraded.channels.count, 5)
        XCTAssertEqual(upgraded.migrated(), upgraded)

        old.channels = [Channel(id: "a", engine: "doubao", name: "渠道 A", on: true)]
        XCTAssertEqual(old.migrated().channels, [Channel(id: "a", engine: "doubao", name: "豆包", on: true)])
    }

    func testConfigMigrationAvoidsChannelIDCollisions() {
        var old = Config.initial
        old.channels = [
            Channel(id: "e", engine: "qwen", name: "渠道 E", on: true),
            Channel(id: "e1", engine: "baidu", name: "我的百度", on: false),
        ]
        old.defaultChannel = "e"
        let upgraded = old.migrated()
        var expected = old.channels
        expected[0].name = "千问"
        XCTAssertEqual(Array(upgraded.channels.prefix(2)), expected)
        XCTAssertEqual(upgraded.channels.last, Channel(id: "e2", engine: "doubao", name: "豆包", on: false))
        XCTAssertEqual(upgraded.active.map(\.id), old.active.map(\.id))
        XCTAssertEqual(upgraded.migrated(), upgraded)
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
        XCTAssertEqual(json["v"] as? Int, 2)
        let u = json["utterance"] as! [String: Any]
        XCTAssertEqual(u["phase"] as? String, "recording")
        XCTAssertEqual((u["rows"] as! [[String: Any]])[0]["state"] as? String, "listening")
        XCTAssertEqual(try JSONDecoder().decode(LiveState.self, from: JSONEncoder().encode(s)), s)

        let c = try JSONDecoder().decode(Command.self, from: Data(#"{"seq":4,"at":1,"op":"continue","utt":1}"#.utf8))
        XCTAssertEqual(c.op, .continue)
        XCTAssertNil(c.tapAt)
        // v1 主 App 写的 state 没有 standby，按常开麦
        let old = try JSONDecoder().decode(LiveState.Session.self, from: Data(#"{"active":true,"idleMinutes":10,"interrupted":true}"#.utf8))
        XCTAssertNil(old.standby)
        XCTAssertTrue(old.micReady)
    }

    // MARK: 待机方式

    func testStandbyDefaultsToPipIncludingUpgrades() throws {
        XCTAssertEqual(Config.initial.standbyMode, .pip)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config.initial)) as! [String: Any]
        json.removeValue(forKey: "standby")
        let upgraded = try JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(upgraded.standbyMode, .pip, "旧版配置升级后默认画中画")
        XCTAssertEqual(upgraded.channels, Config.initial.channels, "升级不丢渠道设置")
        XCTAssertNil(Idle.expiry(lastActivity: 100, seconds: Double(upgraded.idleMinutes * 60), standby: upgraded.standbyMode, busy: false, now: 86400))
        var c = Config.initial
        c.standby = .mic
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.standbyMode, .mic, "切到常开麦后保持")
        XCTAssertNotEqual(back, Config.initial, "切换会触发保存")
    }

    func testMicReadyFallsBackOnlyForInterruptedPip() {
        func s(_ active: Bool, _ interrupted: Bool, _ m: Standby?) -> LiveState.Session {
            .init(active: active, idleMinutes: 10, interrupted: interrupted, standby: m)
        }
        XCTAssertTrue(s(true, false, .pip).micReady)
        XCTAssertFalse(s(true, true, .pip).micReady, "画中画被打断：空心麦克风，点了跳主 App")
        XCTAssertTrue(s(true, true, .mic).micReady, "常开麦被打断仍按原逻辑由主 App 回 micBusy")
        XCTAssertFalse(s(false, false, .pip).micReady)
        XCTAssertFalse(s(false, false, .mic).micReady)
    }

    func testBackgroundMicFailureClassification() {
        XCTAssertEqual(MicPlan.failure(code: 561145187), .bgDenied, "!rec")
        XCTAssertEqual(MicPlan.failure(code: 2003329396), .bgDenied, "what")
        XCTAssertEqual(MicPlan.failure(code: 1), .bgDenied, "未知错误按回主 App 开麦处理")
        XCTAssertEqual(MicPlan.failure(code: 561017449), .micBusy, "!pri 通话占用")
        XCTAssertEqual(MicPlan.failure(code: 560557684), .micBusy, "!int")
        XCTAssertEqual(MicPlan.failure(code: 1936290409), .micBusy, "siri")
    }

    func testPipStandbyNeverHoldsMicOutsideRecording() {
        XCTAssertEqual(MicPlan.steps(.arm, .pip, hot: false), [.category, .pipOn], "待机不激活会话、不开引擎")
        XCTAssertEqual(MicPlan.steps(.record, .pip, hot: false), [.category, .activate, .engineOn])
        XCTAssertEqual(MicPlan.steps(.record, .pip, hot: true), [], "接着说时麦已开就不重复")
        XCTAssertEqual(MicPlan.steps(.recordEnd, .pip, hot: true), [.engineOff, .deactivate], "先停引擎再关会话")
        XCTAssertEqual(MicPlan.steps(.recordEnd, .pip, hot: false), [])
        XCTAssertEqual(MicPlan.steps(.disarm, .pip, hot: true), [.engineOff, .deactivate, .pipOff])
        XCTAssertEqual(MicPlan.steps(.disarm, .pip, hot: false), [.pipOff], "手动结束仍关小窗")

        // 模拟一轮：开会话 → 说 → 停 → 接着说 → 停 → 结束，录音之外麦克风都关着
        var hot = false
        var log: [MicPlan.Step] = []
        func go(_ e: MicPlan.Event) {
            let s = MicPlan.steps(e, .pip, hot: hot)
            log += s
            if s.contains(.engineOn) { hot = true }
            if s.contains(.engineOff) { hot = false }
        }
        go(.arm); XCTAssertFalse(hot)
        go(.record); XCTAssertTrue(hot)
        go(.recordEnd); XCTAssertFalse(hot)
        go(.record); go(.recordEnd); XCTAssertFalse(hot)
        go(.disarm); XCTAssertFalse(hot)
        XCTAssertEqual(log.filter { $0 == .activate }.count, log.filter { $0 == .deactivate }.count, "每次激活都配一次关闭")
        XCTAssertEqual(log.last, .pipOff)
    }

    func testMicStandbyUnchanged() {
        XCTAssertEqual(MicPlan.steps(.arm, .mic, hot: false), [.category, .activate, .engineOn])
        XCTAssertEqual(MicPlan.steps(.record, .mic, hot: true), [], "常开麦录音不重开")
        XCTAssertEqual(MicPlan.steps(.recordEnd, .mic, hot: true), [], "常开麦说完不关麦")
        XCTAssertEqual(MicPlan.steps(.disarm, .mic, hot: true), [.engineOff, .deactivate])
        for e in [MicPlan.Event.arm, .record, .recordEnd, .disarm] {
            XCTAssertFalse(MicPlan.steps(e, .mic, hot: true).contains(.pipOn))
        }
    }
}
