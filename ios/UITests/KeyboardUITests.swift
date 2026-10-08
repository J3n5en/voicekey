import XCTest

/// 真机冒烟：VoiceKey 键盘须已添加并开「允许完全访问」；主 App 用 -fakemic 内置录音代替麦克风。
/// 宿主就是主 App 引导里的「试一试」输入框。
final class KeyboardUITests: XCTestCase {
    private var app: XCUIApplication!
    private var trail: [String] = []

    override func setUp() {
        continueAfterFailure = false
        trail = []
    }

    override func tearDown() {
        let a = XCTAttachment(string: trail.joined(separator: "\n"))
        a.name = "trail"
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: 工具

    private func launch(_ args: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "NO", "-typing", "26"] + args
        app.launch()
        for _ in 0..<12 {
            if tapIf("去试一试") { break }
            if !(tapIf("开始设置（约 1 分钟）") || tapIf("下一步") || tapIf("稍后再说")) { sleep(1) }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.showVoiceKey(mic)
        XCTAssertTrue(mic.exists, "没找到 VoiceKey 键盘")
        XCTAssertTrue(wait(8) { self.label("语音就绪").exists }, "会话没开好")
    }

    @discardableResult
    private func tapIf(_ label: String) -> Bool {
        let b = app.buttons[label]
        guard b.waitForExistence(timeout: 1.5), b.isEnabled else { return false }
        b.tap()
        return true
    }

    private var field: XCUIElement { app.textViews.firstMatch }
    private var text: String {
        let v = (field.value as? String) ?? ""
        return v == field.placeholderValue ? "" : v
    }
    /// 打字界面左上角的麦克风：进语音并开始说
    private var mic: XCUIElement { app.buttons["语音输入"] }
    private func label(_ s: String) -> XCUIElement { app.staticTexts[s] }
    private func key(_ s: String) -> XCUIElement { app.buttons[s] }

    /// 轮询直到条件成立，顺带记下输入框文字的每次变化
    @discardableResult
    private func wait(_ timeout: Double, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            note()
            if ok() { return true }
            usleep(150_000)
        }
        note()
        return ok()
    }

    private func note() {
        let t = text
        if trail.last != t { trail.append(t) }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 最近上屏第一条（打开键盘里的「最近」再关上）
    private func latestHistory() -> String { history().first ?? "" }

    /// 最近上屏，新的在前
    private func history() -> [String] {
        key("最近上屏").tap()
        XCTAssertTrue(label("点一条插入到光标处").waitForExistence(timeout: 3))
        shot("history")
        var cells: [String] = []
        func walk(_ n: XCUIElementSnapshot) {
            if n.elementType == .staticText { cells.append(n.label) }
            n.children.forEach(walk)
        }
        if let s = try? app.snapshot() { walk(s) }
        key("完成").firstMatch.tap()
        guard let i = cells.firstIndex(of: "点一条插入到光标处") else { return [] }
        return stride(from: i + 1, to: cells.count, by: 2).map { cells[$0] }
    }

    /// 一句话结束后回到打字界面
    private var idle: Bool { mic.exists }

    // MARK: 单渠道

    func testSingleChannelTypesLiveAndMatchesFinal() {
        launch(["-arm", "-fakemic", "-enable", "a", "-multi", "0"])
        shot("1-idle")
        key("，").tap()
        XCTAssertEqual(text, "，")
        mic.tap()
        XCTAssertTrue(wait(10) { self.text.count > 3 }, "没有边说边出字")
        shot("2-recording")
        XCTAssertTrue(wait(40) { self.idle }, "没有自动结束")
        shot("3-done")
        let final = latestHistory()
        XCTAssertFalse(final.isEmpty)
        XCTAssertEqual(text, "，" + final, "输入框应恰为用户的字 + 定稿结果")
        XCTAssertGreaterThan(trail.count, 4)
    }

    func testUserEditStopsRewritingWithoutDeleting() {
        launch(["-arm", "-fakemic", "-enable", "a", "-multi", "0"])
        mic.tap()
        XCTAssertTrue(wait(10) { self.text.count >= 2 })
        key("。").tap()
        XCTAssertTrue(wait(3) { self.label("已停止边说边改，避免改动输入框里的其他文字。这句说完后可在「最近」里找到完整结果。").exists }, "改字后没停止改写")
        let frozen = text
        shot("edit-halted")
        XCTAssertTrue(frozen.hasSuffix("。"))
        XCTAssertTrue(wait(40) { self.idle })
        XCTAssertEqual(text, frozen, "停止后不应再改输入框")
        let final = latestHistory()
        XCTAssertFalse(final.isEmpty, "完整结果应进最近上屏")
    }

    func testCursorMoveStopsRewriting() {
        launch(["-arm", "-fakemic", "-enable", "a", "-multi", "0"])
        mic.tap()
        XCTAssertTrue(wait(10) { self.text.count >= 3 })
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.15)).tap()
        XCTAssertTrue(wait(3) { self.label("已停止边说边改，避免改动输入框里的其他文字。这句说完后可在「最近」里找到完整结果。").exists }, "光标移动后没停止改写")
        let frozen = text
        XCTAssertTrue(wait(40) { self.idle })
        XCTAssertEqual(text, frozen)
    }

    // MARK: 多渠道

    func testMultiChannelCandidates() {
        launch(["-arm", "-fakemic", "-enable", "a,b,c", "-multi", "1"])
        mic.tap()
        XCTAssertTrue(wait(5) { self.label("聆听中 · 点按结束").exists }, "候选框没打开")
        XCTAssertTrue(wait(10) { self.text.isEmpty && self.app.buttons["row-a"].label.count > 8 })
        shot("m1-recording")
        XCTAssertTrue(wait(40) { self.label("● 全部完成 · 点一条上屏").exists })
        shot("m2-done")
        XCTAssertEqual(text, "", "多渠道定稿前不上屏")
        // 候选框开着点＝继续听，不关闭
        key("继续听").firstMatch.tap()
        XCTAssertTrue(wait(5) { self.label("聆听中 · 点按结束").exists }, "继续听没开始")
        shot("m3-continue")
        XCTAssertTrue(wait(40) { self.label("● 全部完成 · 点一条上屏").exists })
        let row = app.buttons["row-b"]
        let picked = String(row.label.split(separator: "：", maxSplits: 1).last ?? "")
        shot("m4-done-again")
        row.tap()
        XCTAssertTrue(wait(3) { self.idle })
        XCTAssertEqual(text, picked)
        XCTAssertEqual(latestHistory(), picked)
    }

    func testMultiChannelPickWhileRecording() {
        launch(["-arm", "-fakemic", "-enable", "a,b,c", "-multi", "1"])
        mic.tap()
        XCTAssertTrue(wait(10) { self.app.buttons["row-c"].label.count > 8 })
        app.buttons["row-c"].tap()
        shot("p1-pending")
        XCTAssertTrue(wait(20) { self.idle }, "选中行定稿后应自动上屏")
        XCTAssertEqual(text, latestHistory())
        XCTAssertFalse(text.isEmpty)
    }

    // MARK: 会话提醒

    func testExpiryWarningThenEnded() {
        launch(["-arm", "-fakemic", "-enable", "a", "-multi", "0", "-idlesec", "36"])
        XCTAssertTrue(wait(15) { self.app.staticTexts.containing(NSPredicate(format: "label CONTAINS '后结束 · 现在说话会自动续期'")).firstMatch.exists })
        shot("s1-expiring")
        XCTAssertTrue(wait(40) { self.label("点麦克风说话").exists }, "会话结束后打字界面应提示点麦克风")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '会话已结束'")).firstMatch.exists, "打字时不应用会话结束提醒盖住按键")
        shot("s2-ended")
    }
    // MARK: 无会话：跳主 App 开会话，回来再点一次才开始

    func testNoSessionOpensAppAndWaitsForTapAfterReturn() {
        launch(["-arm", "-enable", "a", "-multi", "0"])
        app.terminate()
        let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")
        notes.launch()
        let compose = notes.buttons.matching(NSPredicate(format: "label == '新备忘录' OR label CONTAINS '新建'")).firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 5), notes.debugDescription)
        // 上次留下的空白备忘录里「新备忘录」是灰的，直接点正文
        if compose.isEnabled { compose.tap() } else { notes.textViews.firstMatch.tap() }
        let nmic = notes.buttons["语音输入"]
        notes.showVoiceKey(nmic)
        XCTAssertTrue(nmic.exists, "备忘录里没找到 VoiceKey 键盘")
        XCTAssertTrue(notes.staticTexts["点麦克风说话"].waitForExistence(timeout: 3), "主 App 被杀后应提示点麦克风")
        shot("n1-outline")
        nmic.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8), "没有跳到 VoiceKey")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '会话已开启'")).firstMatch.waitForExistence(timeout: 8))
        shot("n2-app")
        notes.activate()
        // 回来时键盘可能重开（打字界面）或保留语音界面
        let ready = notes.staticTexts.matching(NSPredicate(format: "label IN {'语音就绪', '点按说话'}")).firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 5), "回来后应是实心麦克风待命")
        sleep(2)
        XCTAssertFalse(notes.staticTexts["点按结束"].exists, "回来后不应自动开始")
        shot("n3-back")
        (nmic.exists ? nmic : notes.buttons.matching(identifier: "麦克风").firstMatch).tap()
        XCTAssertTrue(notes.staticTexts["点按结束"].waitForExistence(timeout: 5), "再点一次应开始说")
        shot("n4-recording")
        notes.buttons.matching(identifier: "麦克风").firstMatch.tap()
        XCTAssertTrue(nmic.waitForExistence(timeout: 15), "说完应回到打字")
    }
}
