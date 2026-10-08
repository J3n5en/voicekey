import XCTest

final class HotkeyTests: XCTestCase {
    @MainActor
    func testOldTimeoutCannotCancelNewRequest() async throws {
        let first = Task { await Hotkey.fire(timeout: 0.1) }
        try await Task.sleep(for: .milliseconds(20))
        let started = Date()
        let second = await Hotkey.fire(timeout: 0.3)
        let firstResult = await first.value
        XCTAssertFalse(firstResult)
        XCTAssertFalse(second)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
    }

    func testOnlyVisibleFullAccessKeyboardAcceptsFreshRequest() {
        let request = HotkeyRequest(id: "one", at: 100)
        XCTAssertTrue(request.accepts(now: 100, visible: true, fullAccess: true, acknowledged: nil))
        XCTAssertFalse(request.accepts(now: 100, visible: false, fullAccess: true, acknowledged: nil))
        XCTAssertFalse(request.accepts(now: 100, visible: true, fullAccess: false, acknowledged: nil))
        XCTAssertFalse(request.accepts(now: 99, visible: true, fullAccess: true, acknowledged: nil))
        XCTAssertFalse(request.accepts(now: 102, visible: true, fullAccess: true, acknowledged: nil))
    }

    func testDuplicateDoesNotToggleRecordingAgain() {
        let request = HotkeyRequest(id: "one", at: 100)
        XCTAssertFalse(request.accepts(now: 101, visible: true, fullAccess: true, acknowledged: "one"))
        XCTAssertTrue(request.accepts(now: 101, visible: true, fullAccess: true, acknowledged: "previous"))
    }

    func testRequestRoundTrip() throws {
        let request = HotkeyRequest()
        let decoded = try JSONDecoder().decode(HotkeyRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.id, request.id)
        XCTAssertEqual(decoded.at, request.at)
        XCTAssertNotEqual(request.id, HotkeyRequest().id)
    }
}
