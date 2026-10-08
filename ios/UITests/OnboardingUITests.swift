import XCTest

/// 真机引导：会改系统设置里的 VoiceKey 键盘与完全访问开关，默认跳过。先 devicectl 卸载 VoiceKey（全新安装），
/// 每个用例单独跑：TEST_RUNNER_VK_ONBOARDING=1 xcodebuild test … -only-testing:VoiceKeyUITests/OnboardingUITests/<用例>
/// testGrantAll：键盘、完全访问逐项打开并在引导输入框里切键盘检测，麦克风点允许。
/// testSkipAll：什么都不开、麦克风点不允许，「下一步」也能走完引导。
final class OnboardingUITests: XCTestCase {
    private let app = XCUIApplication()
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VK_ONBOARDING"] == "1", "引导用例需单独跑")
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "无线数据") { a in
            guard a.buttons["无线局域网与蜂窝网络"].exists else { return false }
            a.buttons["无线局域网与蜂窝网络"].tap()
            return true
        }
        // 卸载不会把键盘移出系统列表，先经引导进设置关掉；设置开着时可能停在旧页面，先关掉
        settings.terminate()
        app.launch()
        app.buttons["开始设置（约 1 分钟）"].tap()
        app.buttons["前往设置"].tap()
        openKeyboardPage()
        setSwitch("允许完全访问", false)
        setSwitch("VoiceKey", false)
        settings.terminate()
        app.terminate()
    }

    func testGrantAll() {
        app.launch()
        // setUp 已走过欢迎页，引导会停在添加键盘这一步
        XCTAssertTrue(text("还没检测到键盘，可以先继续，之后在「设置」里查看。").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["下一步"].isEnabled)
        XCTAssertEqual(ticks, 0)

        // 只加键盘：回前台立刻打勾
        app.buttons["前往设置"].tap()
        openKeyboardPage()
        setSwitch("VoiceKey", true)
        app.activate()
        XCTAssertTrue(text("还没检测到完全访问，可以先继续，之后在「设置」里查看。").waitForExistence(timeout: 3))
        XCTAssertEqual(ticks, 1)

        // 没开完全访问时切到 VoiceKey：提示没开
        switchInProbe { self.text("已切到 VoiceKey，但完全访问还没打开。").exists }
        XCTAssertEqual(ticks, 1)

        // 开完全访问，回来在输入框切到 VoiceKey 后两项都打勾
        app.buttons["前往设置"].tap()
        openKeyboardPage()
        setSwitch("允许完全访问", true)
        app.activate()
        // 打开完全访问会让系统结束 App，回来应仍停在这一步
        XCTAssertTrue(text("添加 VoiceKey 键盘").waitForExistence(timeout: 5), "回来后没停在添加键盘这一步")
        switchInProbe { self.ticks == 2 }
        XCTAssertFalse(app.buttons["前往设置"].exists)

        app.buttons["下一步"].tap()
        XCTAssertTrue(text("未请求").waitForExistence(timeout: 3))
        app.buttons["允许麦克风"].tap()
        let allow = springboard.alerts.buttons["允许"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        allow.tap()
        XCTAssertTrue(text("已允许").waitForExistence(timeout: 3))
        app.buttons["下一步"].tap()
        app.buttons["下一步"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.tabBars.buttons["会话"].waitForExistence(timeout: 3))
    }

    func testSkipAll() {
        app.launch()
        XCTAssertTrue(app.buttons["下一步"].waitForExistence(timeout: 3))
        app.buttons["下一步"].tap()
        app.buttons["允许麦克风"].tap()
        let deny = springboard.alerts.buttons["不允许"]
        XCTAssertTrue(deny.waitForExistence(timeout: 5))
        deny.tap()
        XCTAssertTrue(text("已拒绝").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["去设置开启"].exists)
        app.buttons["下一步"].tap()
        XCTAssertTrue(text("选择识别渠道").waitForExistence(timeout: 3))
        app.buttons["下一步"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.tabBars.buttons["会话"].waitForExistence(timeout: 3))
    }

    // MARK: 工具

    private var ticks: Int { app.staticTexts.matching(identifier: "✓").count }
    private func text(_ s: String) -> XCUIElement { app.staticTexts[s] }

    private func wait(_ timeout: Double, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return true }
            usleep(200_000)
        }
        return ok()
    }

    /// 设置 › VoiceKey › 键盘
    private func openKeyboardPage() {
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 5))
        let kb = settings.cells.staticTexts["键盘"]
        XCTAssertTrue(kb.waitForExistence(timeout: 8), "设置里没有键盘一项")
        kb.tap()
        XCTAssertTrue(settings.switches["VoiceKey"].waitForExistence(timeout: 3))
    }

    private func setSwitch(_ label: String, _ on: Bool) {
        let sw = settings.switches[label]
        guard sw.waitForExistence(timeout: 2), (sw.value as? String == "1") != on else { return }
        sw.tap()
        if on, label == "允许完全访问" {
            let ok = springboard.alerts.buttons["允许"]
            if ok.waitForExistence(timeout: 2) { ok.tap() } else { settings.alerts.buttons["允许"].tap() }
        }
        XCTAssertTrue(wait(3) { (sw.value as? String == "1") == on }, "\(label) 没切到 \(on)")
    }

    /// 在引导输入框里切到 VoiceKey 键盘，直到 done 成立（键盘一出现输入框可能就收起）
    private func switchInProbe(_ done: @escaping () -> Bool) {
        let field = app.textFields["点这里，切到 VoiceKey"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let globe = app.buttons["Next keyboard"]
        for i in 0..<6 {
            if wait(2, done) { return }
            guard globe.exists else { break }
            if i < 3 { globe.tap(); continue }
            globe.press(forDuration: 1.2)
            let item = app.cells.staticTexts["VoiceKey"]
            guard item.waitForExistence(timeout: 2) else { continue }
            let f = item.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
        }
        XCTAssertTrue(wait(3, done), "切到 VoiceKey 后没检测到")
    }
}
