import XCTest
import UIKit

@MainActor
final class KeyPadTests: XCTestCase {
    private final class Touch: UITouch {
        var point: CGPoint = .zero
        override func location(in view: UIView?) -> CGPoint { point }
    }

    func testOverlappingPageChangeLaysOutBeforeNextTouch() throws {
        let pad = KeyPad(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        pad.set(KeyPad.Spec())
        pad.layoutIfNeeded()
        var received: [KeyPad.Key] = []
        pad.onKey = { key in
            received.append(key)
            if case .page(let page) = key {
                var spec = pad.spec
                spec.page = page
                pad.set(spec)
            }
        }
        let page = try XCTUnwrap(pad.keys.first { $0.title(for: .normal) == "123" })
        let last = try XCTUnwrap(pad.keys.first { $0.accessibilityLabel == "p" })
        let first = Touch(), second = Touch()
        first.point = CGPoint(x: page.frame.midX, y: page.frame.midY)
        second.point = CGPoint(x: last.frame.midX, y: last.frame.midY)
        let tracker = try XCTUnwrap(pad.gestureRecognizers?.first)
        let event = UIEvent()
        tracker.touchesBegan([first], with: event)
        tracker.touchesBegan([second], with: event)
        tracker.touchesEnded([second, first], with: event)
        XCTAssertEqual(received, [.page(.num), .text("0")])
    }

    /// 主 App 拖过的九宫格：符拖进右列、中/英拖到右下角 → 123 · 空格(3) · 中/英，右列四个键均分三行
    func testDraggedT9LayoutDrivesKeyPad() throws {
        let pad = KeyPad(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let step = try XCTUnwrap(T9Layout().dropping("sym", x: 4.5, y: 0.8))
        XCTAssertEqual(step.right, ["back", "sym", "newline", "enter"])
        let layout = try XCTUnwrap(step.dropping("lang", x: 4.5, y: 3.5))
        XCTAssertEqual(layout.bottom, ["123", "space", "lang"])
        var picked: [KeyPad.Key] = []
        pad.onKey = { picked.append($0) }
        pad.set(KeyPad.Spec(t9: true, globe: false, t9Layout: layout))
        pad.layoutIfNeeded()
        func key(_ f: (KeyButton) -> Bool) throws -> KeyButton { try XCTUnwrap(pad.keys.first(where: f)) }
        let page = try key { $0.title(for: .normal) == "123" }
        let sym = try key { $0.title(for: .normal) == "符" }
        let space = try key { $0.accessibilityIdentifier == "空格" }
        let lang = try key { $0.accessibilityLabel == "中英切换" }
        let enter = try key { $0.accessibilityIdentifier == "换行" }
        let seven = try key { $0.accessibilityLabel == "7" }, nine = try key { $0.accessibilityLabel == "9" }
        XCTAssertLessThan(page.frame.maxX, space.frame.minX)
        XCTAssertLessThan(space.frame.maxX, lang.frame.minX)
        // 两端的键与标点列 / 右列同宽，空格正好在数字区下方
        XCTAssertEqual(page.frame.width, seven.frame.width, accuracy: 0.5)
        XCTAssertEqual(lang.frame.width, enter.frame.width, accuracy: 0.5)
        XCTAssertEqual(space.frame.minX, seven.frame.minX, accuracy: 0.5)
        XCTAssertEqual(space.frame.maxX, nine.frame.maxX, accuracy: 0.5)
        XCTAssertLessThan(sym.frame.height, nine.frame.height, "右列四个键均分三行")
        XCTAssertEqual(enter.frame.maxY, nine.frame.maxY, accuracy: 0.5)
        XCTAssertEqual(lang.frame.maxX, enter.frame.maxX, accuracy: 0.5)
        // 符打开标点页
        XCTAssertTrue(sym.accessibilityActivate())
        XCTAssertEqual(picked, [.page(.sym)])
    }

    /// 拖动落点与宽度规则：最左键常规宽、空格旁的中间键缩窄；空格进不了右列；非法布局回落默认
    func testT9LayoutDropRules() throws {
        let base = T9Layout()
        XCTAssertEqual(base.bottomWidths, [1, 0.75, 1.5, 0.75], "123 常规宽，空格两旁的符、中/英缩窄")
        XCTAssertEqual(base.cells.first { $0.id == "newline" }?.r, 1, "换行默认在回车上方")
        XCTAssertEqual(base.cells.first { $0.id == "enter" }?.rh, 2, "回车默认两倍高")
        XCTAssertNil(base.dropping("space", x: 4.5, y: 0.5), "空格不能进右列")
        XCTAssertNil(base.dropping("back", x: 2.5, y: 1.5), "数字区不是落点")
        let l = try XCTUnwrap(base.dropping("lang", x: 4.5, y: 1.8))
        XCTAssertEqual(l.right, ["back", "newline", "lang", "enter"])
        XCTAssertEqual(l.cells.first { $0.id == "enter" }?.rh, 1, "右列四个键各一行")
        XCTAssertEqual(l.bottomWidths, [1, 0.75, 2.25])
        // 底行的键拖到右下角：右列不再延伸，底行占满五列，最右键与右列同宽
        let wide = try XCTUnwrap(base.dropping("lang", x: 4.5, y: 3.5))
        XCTAssertFalse(wide.extend)
        XCTAssertEqual(wide.bottomWidths, [1, 0.75, 2.25, 1])
        func decode(_ json: String) -> T9Layout? { try? JSONDecoder().decode(TypingPrefs.self, from: Data(json.utf8)).t9Layout }
        XCTAssertEqual(decode(#"{"t9Layout":{"right":["space","0","enter"],"bottom":["123","lang","back"],"extend":true}}"#), T9Layout(), "非法布局回落默认")
    }

    /// 换行键按输入框的 returnKeyType 显示；组字中始终是「确认」，空输入框的「发送」置灰
    func testReturnKeyFollowsFieldAndComposing() throws {
        let pad = KeyPad(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        pad.set(KeyPad.Spec())
        pad.returnKey = KeyPad.ReturnKey(type: .search, enabled: true)
        let enter = try XCTUnwrap(pad.keys.first { $0.accessibilityIdentifier == "换行" })
        XCTAssertEqual(enter.title(for: .normal), "搜索")
        XCTAssertEqual(enter.style, .enter)
        pad.update(composing: true, pinyin: [])
        XCTAssertEqual(enter.title(for: .normal), "确认")
        XCTAssertEqual(enter.style, .key)
        pad.update(composing: false, pinyin: [])
        pad.returnKey = KeyPad.ReturnKey(type: .send, enabled: false)
        XCTAssertEqual(enter.title(for: .normal), "发送")
        XCTAssertTrue(enter.muted)
        XCTAssertEqual(enter.style, .key, "置灰时不用强调色")
        // 换页重建后仍沿用输入框的动作
        pad.set(KeyPad.Spec(page: .num))
        XCTAssertEqual(pad.keys.first { $0.accessibilityIdentifier == "换行" }?.title(for: .normal), "发送")
    }

    /// 上滑输入数字：26 键 w 上滑出 2，短滑仍是字母；九宫格 5 键上滑出 5，不跳到上一行的键
    func testSwipeUpTypesDigit() throws {
        let pad = KeyPad(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        var received: [KeyPad.Key] = []
        pad.onKey = { received.append($0) }
        let tracker = try XCTUnwrap(pad.gestureRecognizers?.first)
        func swipe(_ key: KeyButton, dy: CGFloat) {
            let t = Touch()
            t.point = CGPoint(x: key.frame.midX, y: key.frame.midY)
            tracker.touchesBegan([t], with: UIEvent())
            t.point.y -= dy
            tracker.touchesMoved([t], with: UIEvent())
            tracker.touchesEnded([t], with: UIEvent())
        }
        pad.set(KeyPad.Spec())
        pad.layoutIfNeeded()
        let w = try XCTUnwrap(pad.keys.first { $0.accessibilityLabel == "w" })
        XCTAssertEqual(w.hint, "2")
        swipe(w, dy: 25)
        swipe(w, dy: 8)
        XCTAssertEqual(received, [.text("2"), .letter("w")])
        received = []
        pad.set(KeyPad.Spec(t9: true))
        pad.layoutIfNeeded()
        let five = try XCTUnwrap(pad.keys.first { $0.accessibilityLabel == "5" })
        XCTAssertEqual(five.hint, "5")
        swipe(five, dy: five.frame.height)
        XCTAssertEqual(received, [.text("5")])
    }

    /// 顶栏顺序：合法排列按存的，缺键或多键回落默认
    func testToolbarOrderDecoding() {
        func decode(_ json: String) -> [String]? { try? JSONDecoder().decode(TypingPrefs.self, from: Data(json.utf8)).toolbar }
        XCTAssertEqual(decode(#"{"toolbar":["chip","status","layout","recent","gear","mic"]}"#), ["chip", "status", "layout", "recent", "gear", "mic"])
        XCTAssertEqual(decode(#"{"toolbar":["mic","status"]}"#), Toolbar.all)
        XCTAssertEqual(decode("{}"), Toolbar.all)
    }

    /// 26 键拖放：底行重排、第三行右端与底行互换；空格上不去、字母不是落点；非法布局回落默认
    func testQwertyLayoutDropRules() throws {
        let base = QwertyLayout()
        XCTAssertEqual(base.bottomCells.first { $0.id == "space" }?.w ?? 0, 3.1, accuracy: 0.001)
        XCTAssertNil(base.dropping("space", x: 9, y: 2.5), "空格不能去第三行")
        XCTAssertNil(base.dropping("lang", x: 4, y: 1.5), "字母不是落点")
        XCTAssertNil(base.dropping("back", x: 5, y: 3.5), "拖到空格上不互换")
        let moved = try XCTUnwrap(base.dropping("lang", x: 9.5, y: 3.5))
        XCTAssertEqual(moved.bottom, ["123", "comma", "space", "period", "enter", "lang"])
        let swapped = try XCTUnwrap(base.dropping("comma", x: 9, y: 2.5))
        XCTAssertEqual(swapped.side, "comma")
        XCTAssertEqual(swapped.bottom, ["123", "lang", "back", "space", "period", "enter"])
        let down = try XCTUnwrap(base.dropping("back", x: 0.5, y: 3.5))
        XCTAssertEqual(down.side, "123")
        XCTAssertEqual(down.bottom.first, "back")
        func decode(_ json: String) -> QwertyLayout? { try? JSONDecoder().decode(TypingPrefs.self, from: Data(json.utf8)).qwerty }
        XCTAssertEqual(decode(#"{"qwerty":{"side":"space","bottom":["123","lang","comma","back","period","enter"]}}"#), QwertyLayout())
    }

    /// 主 App 拖过的 26 键：中/英 换到第三行右端、⌫ 到底行最右，数字页同样生效；九宫格「符」页不受影响
    func testDraggedQwertyLayoutDrivesKeyPad() throws {
        let layout = QwertyLayout(side: "lang", bottom: ["123", "comma", "space", "period", "enter", "back"])
        XCTAssertTrue(layout.valid)
        let pad = KeyPad(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        var picked: [KeyPad.Key] = []
        pad.onKey = { picked.append($0) }
        func key(_ f: (KeyButton) -> Bool) throws -> KeyButton { try XCTUnwrap(pad.keys.first(where: f)) }
        for page in [KeyPad.Page.abc, .num] {
            pad.set(KeyPad.Spec(page: page, globe: true, qwertyLayout: layout))
            pad.layoutIfNeeded()
            let lang = try key { $0.accessibilityLabel == "中英切换" }
            let back = try key { $0.accessibilityLabel == "删除" }
            let enter = try key { $0.accessibilityIdentifier == "换行" }
            let space = try key { $0.accessibilityIdentifier == "空格" }
            let globe = try key { $0.accessibilityLabel == "切换输入法" }
            let pageKey = try key { ["123", "ABC"].contains($0.title(for: .normal)) && $0.frame.minY > lang.frame.maxY }
            XCTAssertLessThan(lang.frame.maxY, space.frame.minY, "中/英在第三行")
            XCTAssertEqual(lang.frame.maxX, back.frame.maxX, accuracy: 0.5, "右端对齐")
            XCTAssertGreaterThan(back.frame.minX, enter.frame.maxX, "⌫ 在底行最右")
            XCTAssertLessThan(pageKey.frame.maxX, globe.frame.minX, "🌐 紧跟 123")
            XCTAssertLessThan(globe.frame.maxX, space.frame.minX)
            XCTAssertTrue(lang.accessibilityActivate())
        }
        XCTAssertEqual(picked, [.lang, .lang])
        pad.set(KeyPad.Spec(t9: true, page: .sym, qwertyLayout: layout))
        pad.layoutIfNeeded()
        let back = try key { $0.accessibilityLabel == "删除" }
        let space = try key { $0.accessibilityIdentifier == "空格" }
        XCTAssertLessThan(back.frame.maxY, space.frame.minY, "九宫格符号页仍是默认布局")
    }
}
