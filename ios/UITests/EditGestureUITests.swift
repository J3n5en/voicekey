import XCTest

/// 真机：空格长按移光标、删除键上滑清空。宿主为备忘录，VoiceKey 键盘须已开「允许完全访问」。
final class EditGestureUITests: XCTestCase {
    private let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")

    override func setUp() { continueAfterFailure = false }

    private var field: XCUIElement { notes.textViews.firstMatch }
    private var text: String { (field.value as? String) ?? "" }
    private func key(_ s: String) -> XCUIElement { notes.buttons[s] }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func openNote() {
        notes.launch()
        let compose = notes.buttons.matching(NSPredicate(format: "label == '新备忘录' OR label CONTAINS '新建'")).firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        if compose.isEnabled { compose.tap() } else { field.tap() }
        let mic = notes.buttons["语音输入"]
        notes.showVoiceKey(mic)
        XCTAssertTrue(mic.exists, "备忘录里没找到 VoiceKey 键盘")
    }

    private func until(_ timeout: Double, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return true }
            usleep(150_000)
        }
        return ok()
    }

    func testSpaceCursorAndSwipeClear() {
        openNote()
        field.typeText("ab😀c")
        XCTAssertTrue(until(3) { self.text == "ab😀c" }, text)
        sleep(1)
        key("空格").tap()
        XCTAssertEqual(text, "ab😀c ", "短按应输入空格")

        sleep(1)
        // 长按空格左移 3 个字（空格、c、😀），松手不插空格
        let space = key("空格").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        space.press(forDuration: 0.5, thenDragTo: space.withOffset(CGVector(dx: -31, dy: 0)), withVelocity: 60, thenHoldForDuration: 0.3)
        XCTAssertEqual(text, "ab😀c ", "移光标不应改字")
        key("，").tap()
        XCTAssertEqual(text, "ab，😀c ", "应按完整字符移动")
        shot("1-cursor")

        // 往下松手：不清空
        let back = key("删除").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        back.press(forDuration: 0.1, thenDragTo: back.withOffset(CGVector(dx: 0, dy: 30)), withVelocity: 600, thenHoldForDuration: 0)
        XCTAssertEqual(text, "ab😀c ", "往下松手只删按下那一个字")

        // 光标在 b 后，按下先删 b；上滑松手：前后都清掉，进「最近」
        back.press(forDuration: 0.1, thenDragTo: back.withOffset(CGVector(dx: 0, dy: -80)), withVelocity: 600, thenHoldForDuration: 0.3)
        XCTAssertTrue(until(3) { self.text.isEmpty }, "应清空，实际：\(text)")
        shot("2-cleared")
        key("最近上屏").tap()
        XCTAssertTrue(notes.staticTexts["点一条插入到光标处"].waitForExistence(timeout: 3))
        XCTAssertTrue(notes.staticTexts["a😀c "].exists, "清掉的文字应进最近")
        XCTAssertTrue(notes.staticTexts.containing(NSPredicate(format: "label ENDSWITH '· 已清空'")).firstMatch.exists)
        shot("3-history")
        notes.staticTexts["a😀c "].firstMatch.tap()
        XCTAssertEqual(text, "a😀c ", "可从最近找回")
        back.press(forDuration: 0.1, thenDragTo: back.withOffset(CGVector(dx: 0, dy: -80)), withVelocity: 600, thenHoldForDuration: 0.3)
        XCTAssertTrue(until(3) { self.text.isEmpty })
    }

    /// 说话中长按空格移光标：按现有规则停止边说边改，完整结果进「最近」
    func testCursorModeDuringDictationStopsRewriting() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboarded", "NO", "-standby", "mic", "-arm", "-fakemic", "-enable", "a", "-multi", "0"]
        app.launch()
        for _ in 0..<12 {
            if app.buttons["去试一试"].waitForExistence(timeout: 1.5) { app.buttons["去试一试"].tap(); break }
            for l in ["开始设置（约 1 分钟）", "下一步", "稍后再说"] where app.buttons[l].exists && app.buttons[l].isEnabled {
                app.buttons[l].tap()
                break
            }
        }
        let field = app.textViews.firstMatch
        let mic = app.buttons["语音输入"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.showVoiceKey(mic)
        XCTAssertTrue(app.staticTexts["语音就绪"].waitForExistence(timeout: 8), "会话没开好")
        var text: String { (field.value as? String).flatMap { $0 == field.placeholderValue ? "" : $0 } ?? "" }
        mic.tap()
        XCTAssertTrue(until(10) { text.count >= 3 }, "没有边说边出字")
        let space = app.buttons["空格"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        space.press(forDuration: 0.5, thenDragTo: space.withOffset(CGVector(dx: -20, dy: 0)), withVelocity: 60, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.staticTexts["已停止边说边改，避免改动输入框里的其他文字。这句说完后可在「最近」里找到完整结果。"].waitForExistence(timeout: 3), "移光标后没停止改写")
        let frozen = text
        shot("d1-halted")
        XCTAssertTrue(until(40) { mic.exists }, "说完应回到打字")
        XCTAssertEqual(text, frozen, "停止后不应再改输入框")
        app.buttons["最近上屏"].tap()
        XCTAssertTrue(app.staticTexts["点一条插入到光标处"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label ENDSWITH '· 微信'")).firstMatch.exists, "完整结果应进最近")
        shot("d2-history")
    }
}
