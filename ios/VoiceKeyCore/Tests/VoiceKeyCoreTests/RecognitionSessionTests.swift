import VoiceKeyCore
import VoiceKeyCoreFFI
import XCTest

final class RecognitionSessionTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(coreVersion.isEmpty)
    }

    func testInvalidSampleRateThrows() {
        XCTAssertThrowsError(try RecognitionSession(engine: .qwen, sampleRate: 0) { _ in })
    }

    func testUnknownEngineRejectedWithoutCallbacks() {
        XCTAssertNil(vk_session_start("nope", 16000, { _, _, _ in fatalError() }, { _ in fatalError() }, nil))
        XCTAssertFalse(vk_run_file("nope", "/x.wav", { _, _, _ in fatalError() }, { _ in fatalError() }, nil))
        XCTAssertFalse(vk_prewarm("nope"))
        XCTAssertFalse(vk_prewarm(nil))
    }

    func testMissingFileFailsOnceThenReleasesHandler() throws {
        let done = expectation(description: "failure")
        let released = expectation(description: "released")
        final class Probe: @unchecked Sendable {
            let onDeinit: () -> Void
            var events: [RecognitionEvent] = []
            init(_ f: @escaping () -> Void) { onDeinit = f }
            deinit { onDeinit() }
        }
        var probe: Probe? = Probe { released.fulfill() }
        try RecognitionSession.recognize(file: URL(fileURLWithPath: "/nonexistent.wav"), engine: .qwen) { [probe] e in
            probe?.events.append(e)
            if case .failure = e { done.fulfill() }
        }
        probe = nil
        wait(for: [done, released], timeout: 5, enforceOrder: true)
    }
}
