import XCTest

/// 真机：画中画待机。主 App 开会话后退到后台只留画中画（全透明、高度约为 0），在备忘录里点麦克风由主 App 后台开麦（-fakemic 只替换音频数据，开麦流程是真的）
final class PipStandbyUITests: XCTestCase {
    private let app = XCUIApplication()
    private let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
    }

    private var field: XCUIElement { notes.textViews.firstMatch }
    private var text: String { (field.value as? String) ?? "" }
    private var mic: XCUIElement { notes.buttons["语音输入"] }

    private func wait(_ timeout: Double, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return true }
            usleep(150_000)
        }
        return ok()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 开会话（小窗）→ 在引导「试一试」里切到 VoiceKey 键盘 → 切到备忘录新建一条
    private func standby(_ extra: [String] = []) {
        app.launchArguments = ["-onboarded", "NO", "-typing", "26", "-standby", "pip", "-arm", "-fakemic", "-enable", "a", "-multi", "0"] + extra
        app.launch()
        func tapIf(_ l: String) -> Bool {
            let b = app.buttons[l]
            guard b.waitForExistence(timeout: 1.5), b.isEnabled else { return false }
            // 小窗可能盖住按钮，点没被盖住的地方
            let f = b.frame, p = pip ?? .zero
            let dx = ([0.5, 0.05, 0.95] as [CGFloat]).first { !p.contains(CGPoint(x: f.minX + f.width * $0, y: f.midY)) } ?? 0.5
            b.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
            return true
        }
        for _ in 0..<12 {
            if tapIf("去试一试") { break }
            if !(tapIf("开始设置（约 1 分钟）") || tapIf("下一步") || tapIf("稍后再说")) { sleep(1) }
        }
        let amic = app.buttons["语音输入"]
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.showVoiceKey(amic)
        XCTAssertTrue(app.staticTexts["语音就绪"].waitForExistence(timeout: 8), "会话没开好")
        shot("app")
        notes.launch()
        // 登了 iCloud 时停在文件夹列表，新建会先弹账户选择；先进「我的iPhone」的备忘录文件夹
        if notes.navigationBars["文件夹"].waitForExistence(timeout: 2) {
            notes.cells.matching(NSPredicate(format: "label == '备忘录'")).allElementsBoundByIndex.last?.tap()
        }
        let compose = notes.buttons.matching(NSPredicate(format: "label == '新备忘录' OR label CONTAINS '新建'")).firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        if compose.isEnabled { compose.tap() } else { field.tap() }
        if !notes.keyboards.firstMatch.waitForExistence(timeout: 3) { field.tap() }
        _ = notes.keyboards.firstMatch.waitForExistence(timeout: 5)
        notes.showVoiceKey(mic)
        XCTAssertTrue(mic.exists, "备忘录里没找到 VoiceKey 键盘")
        XCTAssertTrue(notes.staticTexts["语音就绪"].waitForExistence(timeout: 5), "画中画待机时应是实心麦克风")
        shot("standby")
    }

    /// 实心麦克风待命（打字界面或语音界面）
    private var ready: XCUIElement { notes.staticTexts.matching(NSPredicate(format: "label IN {'语音就绪', '点按说话'}")).firstMatch }
    private var anyMic: XCUIElement { mic.exists ? mic : notes.buttons.matching(identifier: "麦克风").firstMatch }

    /// 说一句：出字并在停顿后自动结束
    private func say(_ name: String) {
        let before = text.count
        anyMic.tap()
        XCTAssertTrue(wait(10) { self.text.count > before + 2 }, "\(name)：没有出字")
        XCTAssertTrue(wait(40) { self.ready.exists }, "\(name)：没有结束")
        shot(name)
    }

    /// 空心麦克风 → 点了跳主 App 重开小窗 → 回来接着说。fake = false：主 App 是键盘冷启动的，用真麦克风，只看能开始录音
    private func reopenFromKeyboard(_ name: String, fake: Bool = true) {
        XCTAssertTrue(notes.staticTexts.matching(NSPredicate(format: "label IN {'点麦克风说话', '点按开启会话', '点按回 VoiceKey'}")).firstMatch.waitForExistence(timeout: 10), "\(name)：应变空心麦克风")
        shot("\(name)-hollow")
        anyMic.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8), "\(name)：没有跳到 VoiceKey")
        XCTAssertTrue(app.staticTexts["画中画待命"].waitForExistence(timeout: 8), "\(name)：回主 App 应重新开小窗")
        shot("\(name)-app")
        notes.activate()
        XCTAssertTrue(ready.waitForExistence(timeout: 6), "\(name)：回来后应是实心麦克风")
        if fake { return say("\(name)-again") }
        anyMic.tap()
        let stop = notes.staticTexts["点按结束"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "\(name)：回来后应能开始录音")
        shot("\(name)-recording")
        anyMic.tap()
        XCTAssertTrue(wait(15) { self.ready.exists || self.mic.exists }, "\(name)：结束后应回到待命")
    }

    /// 屏幕上的画中画窗口（不含系统放在屏幕外的占位）
    private var pip: CGRect? {
        guard let s = try? springboard.snapshot() else { return nil }
        let w = s.frame.width
        func find(_ n: XCUIElementSnapshot) -> CGRect? {
            if n.identifier == "PIP-SBInteractionPassThroughView", n.frame.width > 60, n.frame.minX < w { return n.frame }
            for c in n.children { if let f = find(c) { return f } }
            return nil
        }
        return find(s)
    }

    /// 连说 5 句：后台开麦、出字、停顿自动结束
    func testRecordsInBackgroundFiveTimes() {
        standby()
        for i in 1...5 {
            say("round-\(i)")
            sleep(2)
        }
    }

    /// 画中画看不见：窗口高度约为 0，主屏截图里没有窗口和把手，照常能用
    func testPipInvisible() {
        standby()
        guard let w = pip else { return XCTFail("画中画没开") }
        XCTAssertLessThan(w.height, 1, "画中画窗口应看不见")
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("home")
        notes.activate()
        XCTAssertTrue(ready.waitForExistence(timeout: 6))
        say("invisible-1")
    }

    /// 主 App 被杀：键盘变空心麦克风，点了冷启动主 App 重开小窗
    func testKilledAppFallsBack() {
        standby()
        app.terminate()
        reopenFromKeyboard("killed", fake: false)
    }

    /// 超过原闲置时长仍待命，无到期提醒；手动结束仍关闭画中画
    func testIdleDoesNotEndPipButManualEndDoes() {
        standby(["-idlesec", "40"])
        XCTAssertNotNil(pip)
        let notice = notes.staticTexts.matching(NSPredicate(format: "label CONTAINS '后结束'"))
        for _ in 0..<60 {
            XCTAssertTrue(ready.exists, "超过原闲置时长仍应待命")
            XCTAssertFalse(notice.firstMatch.exists, "画中画不应显示闲置倒计时")
            sleep(1)
        }
        XCTAssertNotNil(pip)
        app.activate()
        for _ in 0..<2 where !app.buttons["结束会话"].exists {
            XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
            app.buttons["完成"].tap()
        }
        XCTAssertTrue(app.buttons["结束会话"].waitForExistence(timeout: 5))
        app.buttons["结束会话"].tap()
        XCTAssertTrue(app.staticTexts["未开启"].waitForExistence(timeout: 5))
        XCTAssertTrue(wait(5) { self.pip == nil })
    }

    /// 锁屏再解锁后还能用
    func testLockUnlock() {
        standby()
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        sleep(8)
        XCUIDevice.shared.press(.home)
        sleep(2)
        if notes.state != .runningForeground {
            springboard.swipeUp()
            sleep(1)
        }
        notes.activate()
        shot("unlocked")
        if ready.waitForExistence(timeout: 6) { say("after-lock") } else { reopenFromKeyboard("after-lock") }
    }

    /// 长待机（分钟数由 TEST_RUNNER_VK_STANDBY_MIN 指定）后照常能用
    func testLongStandby() {
        let min = Int(ProcessInfo.processInfo.environment["VK_STANDBY_MIN"] ?? "") ?? 1
        standby(["-idlesec", "0"])
        shot("standby-0min")
        for m in 1...max(1, min) {
            sleep(60)
            print("standby \(m) min, pip=\(pip != nil)")
            if [1, 5, 15].contains(m) { shot("standby-\(m)min") }
        }
        XCTAssertTrue(ready.exists, "待机后应仍是实心麦克风")
        say("after-\(min)min")
    }
}
