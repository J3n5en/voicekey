import XCTest

/// 模拟宿主输入框：deleteBackward 按整份文字的字符（字素簇）删
private final class Field: TextTarget {
    var head: String
    var tail: String
    var sel = ""
    var limit: Int?
    var noContext = false
    /// 光标前没有字时 before 给 nil（不少宿主如此）
    var nilWhenEmpty = false
    var refuseDelete = false
    /// 非 nil 时 before 返回这个旧值，模拟宿主同步慢一拍
    var stale: String?
    private(set) var deletes = 0

    init(_ head: String = "", _ tail: String = "") {
        self.head = head
        self.tail = tail
    }

    var text: String { head + tail }
    var before: String? {
        if noContext { return nil }
        let b = stale ?? head
        if nilWhenEmpty, b.isEmpty { return nil }
        return limit.map { String(b.suffix($0)) } ?? b
    }
    var after: String? { noContext ? nil : tail }
    var selected: String? { sel }
    func insert(_ t: String) {
        sel = ""
        head += t
    }
    func deleteBackward() {
        deletes += 1
        if !refuseDelete, !head.isEmpty { head.removeLast() }
    }
    /// 用户把光标挪到第 n 个字符后
    func moveCursor(to n: Int) {
        let all = text
        head = String(all.prefix(n))
        tail = String(all.dropFirst(n))
    }
}

final class LiveTyperTests: XCTestCase {
    func testRetypesOnlyDifferingTail() {
        let f = Field("备注：", "（完）")
        let t = LiveTyper(f)
        for s in ["今天", "今天天气", "今天天汽很好", "今天天气很好。"] { XCTAssertEqual(t.set(s), .synced) }
        XCTAssertEqual(f.text, "备注：今天天气很好。（完）")
        XCTAssertEqual(f.deletes, 4)
        XCTAssertEqual(t.set(""), .synced)
        XCTAssertEqual(f.text, "备注：（完）", "删到空也只删自己打的字")
    }

    func testEmojiCountsAsOneCharacter() {
        let f = Field("hi ")
        let t = LiveTyper(f)
        t.set("好👨‍👩‍👧")
        t.set("好👨‍👩‍👧啊🇨🇳")
        XCTAssertEqual(f.deletes, 0)
        t.set("好😀")
        XCTAssertEqual(f.text, "hi 好😀")
        XCTAssertEqual(f.deletes, 3)
        t.set("好😀👍🏽")
        t.set("好😀👍")
        XCTAssertEqual(f.text, "hi 好😀👍")
        XCTAssertEqual(f.deletes, 4)
    }

    func testCombiningCharactersInsideOwnText() {
        let f = Field("x")
        let t = LiveTyper(f)
        t.set("cafe\u{301}s")
        t.set("cafe\u{301}!")
        XCTAssertEqual(f.deletes, 1)
        XCTAssertEqual(f.text, "xcafe\u{301}!")
        t.set("caf")
        XCTAssertEqual(f.text, "xcaf")
    }

    func testRefusesToJoinUsersLastCharacter() {
        let f = Field("cafe")
        let t = LiveTyper(f)
        XCTAssertEqual(t.set("\u{301}好"), .halted(.boundary))
        XCTAssertEqual(f.text, "cafe")
        let g = Field("👍")
        XCTAssertEqual(LiveTyper(g).set("\u{1F3FD}"), .halted(.boundary))
        XCTAssertEqual(g.text, "👍")
        let h = Field("abc")
        h.noContext = true
        XCTAssertEqual(LiveTyper(h).set("\u{200D}x"), .halted(.boundary))
    }

    func testCursorMovedStopsRewriting() {
        let f = Field("用户原文")
        let t = LiveTyper(f)
        t.set("我们打的")
        f.moveCursor(to: 2)
        XCTAssertEqual(t.set("我们打得"), .waiting)
        XCTAssertEqual(t.sync(), .waiting)
        XCTAssertEqual(t.sync(), .halted(.diverged))
        XCTAssertEqual(t.set("x"), .halted(.diverged))
        XCTAssertEqual(f.text, "用户原文我们打的")
        XCTAssertEqual(f.deletes, 0)
    }

    func testUserEditStopsRewriting() {
        let f = Field()
        let t = LiveTyper(f)
        t.set("明天开会")
        f.head += "！"
        for _ in 0..<LiveTyper.patience { _ = t.set("明天开") }
        XCTAssertEqual(t.halt, .diverged)
        XCTAssertEqual(f.text, "明天开会！")

        let g = Field("abc")
        let u = LiveTyper(g)
        u.set("你好")
        g.head.removeLast()
        for _ in 0..<LiveTyper.patience { _ = u.set("你") }
        XCTAssertEqual(g.text, "abc你", "用户删过的字不再动")
        XCTAssertEqual(g.deletes, 0)
    }

    func testSelectionStopsRewriting() {
        let f = Field("abc")
        let t = LiveTyper(f)
        t.set("你好")
        f.sel = "abc"
        for _ in 0..<LiveTyper.patience { _ = t.set("你们") }
        XCTAssertEqual(t.halt, .diverged)
        XCTAssertEqual(f.text, "abc你好")
    }

    func testFieldClearedAfterSend() {
        let f = Field()
        let t = LiveTyper(f)
        t.set("发出去了")
        f.head = ""
        for _ in 0..<LiveTyper.patience { _ = t.set("发出去") }
        XCTAssertEqual(t.halt, .diverged)
        XCTAssertEqual(f.deletes, 0)
        XCTAssertEqual(f.text, "")
    }

    func testHostRefusingDeletionNeverAppendsAfterStaleTail() {
        let f = Field("前文")
        let t = LiveTyper(f)
        t.set("天气很好")
        f.refuseDelete = true
        XCTAssertEqual(t.set("天气不错"), .waiting)
        XCTAssertEqual(t.sync(), .waiting)
        XCTAssertEqual(t.sync(), .halted(.diverged))
        XCTAssertEqual(f.text, "前文天气很好")
    }

    func testNoContextAppendsButNeverDeletes() {
        let f = Field("用户")
        f.noContext = true
        let t = LiveTyper(f)
        XCTAssertEqual(t.set("一"), .synced)
        XCTAssertEqual(t.set("一二"), .synced)
        XCTAssertEqual(t.set("一三"), .halted(.unverifiable))
        XCTAssertEqual(f.text, "用户一二")
        XCTAssertEqual(f.deletes, 0)
    }

    func testEmptyFieldWithNilContextStillRevises() {
        let f = Field()
        f.nilWhenEmpty = true
        let t = LiveTyper(f)
        t.set("今天")
        XCTAssertEqual(t.set("今天天汽"), .synced)
        XCTAssertEqual(t.set("今天天气"), .synced)
        XCTAssertEqual(f.text, "今天天气")
        f.head = ""
        for _ in 0..<LiveTyper.patience { _ = t.set("今天") }
        XCTAssertEqual(t.halt, .diverged, "发送后输入框清空，不能再删")
    }

    func testRevisingWholeTextInEmptyField() {
        let f = Field()
        f.nilWhenEmpty = true
        let t = LiveTyper(f)
        t.set("气")
        XCTAssertEqual(t.set("天气"), .synced, "删光后输入框给 nil 也要能补打")
        XCTAssertEqual(t.set("今天天气"), .synced)
        XCTAssertEqual(t.set("J"), .synced)
        XCTAssertEqual(t.set(""), .synced)
        XCTAssertEqual(t.set("今天"), .synced)
        XCTAssertEqual(f.text, "今天")
        XCTAssertNil(t.halt)
    }

    func testTruncatedContextStillVerifies() {
        let f = Field("很长的一段用户原文")
        f.limit = 4
        let t = LiveTyper(f)
        t.set("我们说了很长很长的一句话")
        XCTAssertEqual(t.set("我们说了很长很长的一句画。"), .synced)
        XCTAssertEqual(f.text, "很长的一段用户原文我们说了很长很长的一句画。")
        XCTAssertEqual(t.set("我们说了很长很长的一句话。"), .synced)
        XCTAssertEqual(f.text, "很长的一段用户原文我们说了很长很长的一句话。")
    }

    func testLaggingContextWaitsInsteadOfHalting() {
        let f = Field("a")
        let t = LiveTyper(f)
        t.set("你好")
        f.stale = "a"
        XCTAssertEqual(t.set("你好吗"), .waiting)
        f.stale = nil
        XCTAssertEqual(t.sync(), .synced)
        XCTAssertEqual(f.text, "a你好吗")
        XCTAssertNil(t.halt)
    }

    func testAbandonFreezesText() {
        let f = Field()
        let t = LiveTyper(f)
        t.set("一句")
        t.abandon()
        XCTAssertEqual(t.set(""), .halted(.diverged))
        XCTAssertEqual(f.text, "一句")
    }

    func testJoinsPrevious() {
        for s in ["\u{301}", "\u{1F3FD}", "\u{200D}", "\u{FE0F}", "\u{1F1E8}", "\u{1161}"] {
            XCTAssertTrue(LiveTyper.joinsPrevious(s.unicodeScalars.first!), s)
        }
        for s in ["a", "好", "。", "😀", "가"] { XCTAssertFalse(LiveTyper.joinsPrevious(s.unicodeScalars.first!), s) }
    }
}

final class DictationTests: XCTestCase {
    private func utt(_ phase: LiveState.Phase, _ rows: [(String, LiveState.RowState, String)]) -> LiveState.Utterance {
        .init(id: 9, startSeq: 3, phase: phase, level: 0,
              rows: rows.map { .init(channel: $0.0, name: $0.0, text: $0.2, state: $0.1) }, retryable: true)
    }

    func testTapFollowsDesktopRules() {
        XCTAssertEqual(Dictation.tap(nil), .begin)
        XCTAssertEqual(Dictation.tap(utt(.recording, [("a", .listening, "")])), .stop(9))
        XCTAssertEqual(Dictation.tap(utt(.finalizing, [("a", .finalizing, "x")])), .resume(9))
        XCTAssertEqual(Dictation.tap(utt(.done, [("a", .final, "x"), ("b", .final, "y")])), .resume(9), "候选框开着点＝继续听，不关闭")
        XCTAssertEqual(Dictation.tap(utt(.done, [("a", .error, "")])), .begin)
        XCTAssertEqual(Dictation.tap(utt(.failed, [])), .begin)
        XCTAssertEqual(Dictation.mode(utt(.done, [("a", .final, "x")])), .idle)
        XCTAssertEqual(Dictation.mode(utt(.done, [("a", .error, "")])), .failed)
        XCTAssertEqual(Dictation.mode(utt(.done, [("a", .error, ""), ("b", .error, "")])), .picking)
    }

    func testPickRow() {
        let rec = utt(.recording, [("a", .listening, "x"), ("b", .listening, "")])
        XCTAssertEqual(Dictation.pick("b", in: rec), .stopAndWait("b"))
        let fin = utt(.finalizing, [("a", .final, "x"), ("b", .finalizing, "y"), ("c", .error, ""), ("d", .final, "")])
        XCTAssertEqual(Dictation.pick("a", in: fin), .commit("a"))
        XCTAssertEqual(Dictation.pick("b", in: fin), .wait("b"))
        XCTAssertEqual(Dictation.pick("c", in: fin), .unavailable("c"))
        XCTAssertEqual(Dictation.pick("d", in: fin), .unavailable("d"))
        XCTAssertEqual(Dictation.pick("z", in: fin), .unavailable("z"))
    }

    func testSettlePending() {
        XCTAssertEqual(Dictation.settle(pending: "a", in: utt(.recording, [("a", .final, "x")])), .keep)
        XCTAssertEqual(Dictation.settle(pending: "b", in: utt(.finalizing, [("a", .final, "x"), ("b", .finalizing, "")])), .keep)
        XCTAssertEqual(Dictation.settle(pending: "b", in: utt(.finalizing, [("a", .final, "x"), ("b", .final, "y")])), .commit("b"))
        XCTAssertEqual(Dictation.settle(pending: "b", in: utt(.done, [("a", .final, "x"), ("b", .error, "")])), .failed(fallback: "a"))
        XCTAssertEqual(Dictation.settle(pending: "b", in: utt(.done, [("a", .error, ""), ("b", .error, "")])), .failed(fallback: nil))
    }

    func testSelectionDefaultsToLastPickAndSkipsFailures() {
        let rows = utt(.finalizing, [("a", .listening, ""), ("b", .listening, ""), ("c", .listening, "")]).rows
        XCTAssertEqual(Dictation.selection(nil, lastPick: "b", rows: rows), "b")
        XCTAssertEqual(Dictation.selection(nil, lastPick: "z", rows: rows), "a")
        XCTAssertEqual(Dictation.selection("c", lastPick: "b", rows: rows), "c")
        let bad = utt(.done, [("a", .final, "x"), ("b", .error, ""), ("c", .final, "y")]).rows
        XCTAssertEqual(Dictation.selection(nil, lastPick: "b", rows: bad), "a")
        XCTAssertNil(Dictation.selection(nil, lastPick: nil, rows: []))
    }
}
