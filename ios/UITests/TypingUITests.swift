import XCTest

/// 真机：26 键全拼、九宫格打字，并在键盘进程里读按键耗时与内存（-typing metrics 时键盘底部显示）。
/// 宿主为主 App 引导里的「试一试」输入框，VoiceKey 键盘须已添加并开「允许完全访问」。
final class TypingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() { continueAfterFailure = false }

    /// 还原成默认 26 键、关掉耗时显示
    override func tearDown() {
        let a = XCUIApplication()
        a.launchArguments = ["-typing", "26"]
        a.launch()
        a.terminate()
    }

    private func launch(_ typing: String) {
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "NO", "-typing", typing]
        app.launch()
        for _ in 0..<12 {
            if tapIf("去试一试") { break }
            if !(tapIf("开始设置（约 1 分钟）") || tapIf("下一步") || tapIf("稍后再说")) { sleep(1) }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.showVoiceKey(key("语音输入"))
        XCTAssertTrue(key("语音输入").exists, "没找到 VoiceKey 键盘（应默认打字）")
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
    private func key(_ s: String) -> XCUIElement { app.buttons[s] }
    private var first: XCUIElement { app.buttons["cand0"] }
    private var metrics: String { app.staticTexts["metrics"].label }

    /// 按键区的键（候选条里也可能有同名的字）
    private func pad(_ s: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH 'cand')", s)).firstMatch
    }

    private func type(_ keys: String) {
        for c in keys { pad(String(c)).tap() }
    }

    /// 按空格选首选直到组字结束
    private func commitFirst() {
        for _ in 0..<12 where first.exists { key("空格").tap() }
        XCTAssertFalse(first.exists)
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// 记下键盘进程里的耗时与内存，并检查不超标
    private func report(_ name: String) {
        let s = metrics
        print("METRICS \(name): \(s)")
        let a = XCTAttachment(string: s)
        a.name = "metrics-\(name)"
        a.lifetime = .keepAlways
        add(a)
        var v: [String: Double] = [:]
        for part in s.split(separator: " ") {
            let kv = part.split(separator: "=")
            if kv.count == 2 { v[String(kv[0])] = Double(kv[1].split(separator: "/").last ?? "") }
        }
        XCTAssertLessThan(v["peak"] ?? 999, 60, "键盘进程内存峰值过高：\(s)")
        XCTAssertLessThan(v["p95"] ?? 999, 100, "按键耗时 p95 过高：\(s)")
    }

    func testQwerty() {
        launch("26,metrics")
        type("nihao")
        XCTAssertEqual(first.label, "你好")
        XCTAssertEqual(app.staticTexts["preedit"].label, "ni'hao")
        shot("q1-composing")
        key("空格").tap()
        XCTAssertEqual(text, "你好")

        // 标点先按首选上屏
        type("women")
        key("，").tap()
        XCTAssertEqual(text, "你好我们，")

        // 组字中删一键；确认＝上屏字母
        type("xie")
        key("删除").tap()
        XCTAssertEqual(app.staticTexts["preedit"].label, "xi")
        key("确认").tap()
        XCTAssertEqual(text, "你好我们，xi")

        // 展开候选
        type("shi")
        key("更多候选").tap()
        XCTAssertTrue(app.collectionViews["cand-grid"].waitForExistence(timeout: 2))
        shot("q2-grid")
        key("收起").tap()
        key("确认").tap()

        // 连续打一段，测耗时
        for w in ["mingtian", "xiawu", "sandian", "zaihuiyishi", "kaihui", "xiexie", "shoudao", "women", "huilai"] {
            type(w)
            commitFirst()
        }
        XCTAssertTrue(text.hasPrefix("你好我们，xishi"), text)
        shot("q3-typed")

        // 中英切换：英文直接上屏，⇧ 只管一个字母
        key("中英切换").tap()
        key("大写").tap()
        type("ok")
        XCTAssertTrue(text.hasSuffix("Ok"), text)
        key("123").tap()
        pad("7").tap()
        XCTAssertTrue(text.hasSuffix("Ok7"), text)
        key("ABC").tap()
        key("中英切换").tap()
        report("qwerty")
    }

    func testT9() {
        launch("t9,metrics")
        type("64426")
        XCTAssertEqual(first.label, "你好")
        shot("t1-composing")
        key("空格").tap()
        XCTAssertEqual(text, "你好")

        // 左列选拼音收窄候选
        type("94")
        XCTAssertTrue(app.scrollViews["t9-list"].buttons["xi"].exists)
        app.scrollViews["t9-list"].buttons["xi"].tap()
        XCTAssertEqual(app.staticTexts["preedit"].label, "xi")
        first.tap()
        XCTAssertEqual(text.count, 3)

        // 1 键空闲时轮换英文符号，空格上屏当前符号
        type("11")
        XCTAssertEqual(first.label, ".")
        key("空格").tap()
        XCTAssertTrue(text.hasSuffix("."), text)
        // 0 单独一个键
        pad("0").tap()
        XCTAssertTrue(text.hasSuffix(".0"), text)
        // 空闲时左列为中文标点
        app.scrollViews["t9-list"].buttons["。"].tap()
        XCTAssertTrue(text.hasSuffix(".0。"), text)

        for d in ["64632", "9426", "7448", "24", "43", "94", "9433", "642", "4846", "736"] {
            type(d)
            commitFirst()
        }
        shot("t2-typed")

        // 英文不做九宫格
        key("中英切换").tap()
        XCTAssertTrue(key("q").waitForExistence(timeout: 2), "英文应为 26 键")
        key("中英切换").tap()
        XCTAssertTrue(key("2").waitForExistence(timeout: 2))
        report("t9")

        // 切布局同步改默认：重开键盘后仍是 26 键
        key("26").tap()
        XCTAssertTrue(key("q").waitForExistence(timeout: 2))
        app.terminate()
        app.launchArguments = ["-onboarded", "NO"]
        app.launch()
        for _ in 0..<12 {
            if tapIf("去试一试") { break }
            if !(tapIf("开始设置（约 1 分钟）") || tapIf("下一步") || tapIf("稍后再说")) { sleep(1) }
        }
        XCTAssertTrue(key("语音输入").waitForExistence(timeout: 5))
        XCTAssertTrue(key("q").exists, "切过的布局应成为默认")
    }
}
