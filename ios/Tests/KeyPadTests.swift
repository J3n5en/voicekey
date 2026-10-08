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
}
