import XCTest

final class CursorWalkTests: XCTestCase {
    func testStepsFollowFingerInWholeSteps() {
        var w = CursorWalk(before: "", after: "", x: 100)
        let s = CursorWalk.stepWidth
        XCTAssertEqual(w.steps(to: 100 + s * 0.9), 0)
        XCTAssertEqual(w.steps(to: 100 + s * 1.2), 1)
        XCTAssertEqual(w.steps(to: 100 + s * 3.5), 2)
        XCTAssertEqual(w.steps(to: 100 + s * 1.4), -1)
        XCTAssertEqual(w.steps(to: 100 + s * 1.2), 0)
        XCTAssertEqual(w.steps(to: 100 - s * 0.1), -2)
    }

    func testStepsOverWholeCharacters() {
        // é 由 e + 组合重音组成，👨‍👩‍👧 是 ZWJ 序列，🇨🇳 是旗帜：都只算一个字
        var w = CursorWalk(before: "a😀e\u{301}", after: "👨‍👩‍👧🇨🇳b", x: 0)
        XCTAssertEqual(w.step(-1), -2)
        XCTAssertEqual(w.step(-1), -2)
        XCTAssertEqual(w.step(-1), -1)
        XCTAssertNil(w.step(-1))
        XCTAssertEqual(w.step(1), 1)
        XCTAssertEqual(w.step(1), 2)
        XCTAssertEqual(w.step(1), 2)
        XCTAssertEqual(w.step(1), "👨‍👩‍👧".utf16.count)
        XCTAssertEqual(w.step(1), 4)
        XCTAssertEqual(w.step(1), 1)
        XCTAssertNil(w.step(1))
    }

    func testRefillKeepsFingerOrigin() {
        var w = CursorWalk(before: "", after: "", x: 0)
        XCTAssertNil(w.step(1))
        w.refill(before: "x", after: "中文")
        XCTAssertEqual(w.step(1), 1)
        XCTAssertEqual(w.steps(to: CursorWalk.stepWidth), 1)
    }
}

final class ClearSwipeTests: XCTestCase {
    func testArmsAboveThresholdAndCancelsWhenBack() {
        var s = ClearSwipe(y: 300)
        s.move(to: 300 - ClearSwipe.arm + 1)
        XCTAssertFalse(s.armed)
        XCTAssertFalse(s.swiped)
        s.move(to: 300 - ClearSwipe.arm - 1)
        XCTAssertTrue(s.armed)
        XCTAssertTrue(s.swiped)
        // 滞回：稍微回落仍保持
        s.move(to: 300 - ClearSwipe.disarm - 1)
        XCTAssertTrue(s.armed)
        s.move(to: 300 - ClearSwipe.disarm + 1)
        XCTAssertFalse(s.armed)
        // 上滑过一次，本次按压不再连删
        XCTAssertTrue(s.swiped)
        s.move(to: 360)
        XCTAssertFalse(s.armed)
    }
}

final class ClearPlanTests: XCTestCase {
    func testMovesToEndThenDeletesBackwardWindowByWindow() {
        var p = ClearPlan()
        XCTAssertEqual(p.next(before: "前面", after: "后面😀"), .toEnd(4))
        XCTAssertEqual(p.next(before: "前面后面😀", after: nil), .delete(5))
        XCTAssertEqual(p.next(before: "更早的", after: ""), .delete(3))
        XCTAssertEqual(p.next(before: "", after: nil), .done)
        XCTAssertEqual(p.text, "更早的前面后面😀")
    }

    func testEmptyFieldIsDoneImmediately() {
        var p = ClearPlan()
        XCTAssertEqual(p.next(before: "", after: ""), .done)
        XCTAssertEqual(p.text, "")
    }

    /// 真机备忘录：回删后先给 nil，再给删之前的旧上下文，过一会儿才更新
    func testWaitsForHostToCatchUp() {
        var p = ClearPlan()
        XCTAssertEqual(p.next(before: nil, after: nil), .wait)
        XCTAssertEqual(p.next(before: "a😀c ", after: nil), .delete(4))
        XCTAssertEqual(p.next(before: nil, after: nil), .wait)
        XCTAssertEqual(p.next(before: "a😀c ", after: nil), .wait)
        XCTAssertEqual(p.next(before: "更早", after: nil), .delete(2))
        XCTAssertEqual(p.next(before: nil, after: nil), .wait)
        XCTAssertEqual(p.next(before: "", after: ""), .done)
        XCTAssertEqual(p.text, "更早a😀c ")
    }

    func testStopsWhenHostNeverCatchesUp() {
        var p = ClearPlan()
        XCTAssertEqual(p.next(before: "abc", after: ""), .delete(3))
        for _ in 0 ..< ClearPlan.maxWaits { XCTAssertEqual(p.next(before: "abc", after: ""), .wait) }
        XCTAssertEqual(p.next(before: "abc", after: ""), .done)
        XCTAssertEqual(p.text, "abc")
    }

    func testNoContextAtAllGivesUp() {
        var p = ClearPlan()
        for _ in 0 ..< ClearPlan.maxWaits { XCTAssertEqual(p.next(before: nil, after: nil), .wait) }
        XCTAssertEqual(p.next(before: nil, after: nil), .done)
        XCTAssertEqual(p.text, "")
    }

    func testRoundLimitPreventsEndlessLoop() {
        var p = ClearPlan()
        var ops = 0
        while p.next(before: "x\(ops)", after: "") != .done { ops += 1 }
        XCTAssertEqual(ops, ClearPlan.maxRounds)
    }
}
