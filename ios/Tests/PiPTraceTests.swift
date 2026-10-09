import XCTest

final class PiPTraceTests: XCTestCase {
    func testRateLimitAndGapAreExplicit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var now = 0.0
        let trace = PiPTrace(url: url, clock: { now })
        for _ in 0..<10 { trace.record("state", throttle: true) }
        XCTAssertEqual(try String(contentsOf: url).split(separator: "\n").count, 8)
        trace.record("didStart")
        XCTAssertTrue(try String(contentsOf: url).contains("omitted=2 didStart"))
        now = 1
        trace.record("next", throttle: true)
        XCTAssertTrue(try String(contentsOf: url).contains("omitted=0 next"))
    }

    func testTimeBudgetStopsAndDoesNotEvaluatePayload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var now = 0.0
        let trace = PiPTrace(url: url, clock: { now })
        trace.record("begin")
        now = 601
        trace.record("not recorded")
        let final = try Data(contentsOf: url)
        XCTAssertTrue(String(decoding: final, as: UTF8.self).contains("END budget"))
        var evaluated = false
        func payload() -> String { evaluated = true; return "unexpected" }
        trace.record(payload())
        XCTAssertFalse(evaluated)
        XCTAssertEqual(try Data(contentsOf: url), final)
    }

    func testByteAndEventBudgetsBoundDiskUse() throws {
        for payload in ["state", String(repeating: "x", count: 2000)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            var now = 0.0
            let trace = PiPTrace(url: url, clock: { now })
            for _ in 0..<550 { now += 1; trace.record(payload) }
            let data = try Data(contentsOf: url)
            XCTAssertLessThan(data.count, 128_000)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("END budget"))
        }
    }
}
