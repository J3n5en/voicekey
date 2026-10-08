import XCTest

extension XCUIApplication {
    /// 切到 VoiceKey 键盘：先点 🌐 轮换；装了别的第三方键盘时 🌐 可能只在两个键盘间来回，就长按 🌐 从列表里点 VoiceKey
    func showVoiceKey(_ marker: XCUIElement) {
        let globe = buttons["Next keyboard"]
        for _ in 0..<3 {
            if marker.waitForExistence(timeout: 2) { return }
            globe.tap()
        }
        for _ in 0..<2 where !marker.waitForExistence(timeout: 2) {
            globe.press(forDuration: 1.2)
            let item = cells.staticTexts["VoiceKey"]
            guard item.waitForExistence(timeout: 2) else { continue }
            // 列表在系统窗口里，按元素点不生效，按屏幕坐标点
            let f = item.frame
            coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
        }
    }
}
