import Foundation

/// Opt-in state-only trace. A terminal marker means the timeline is incomplete.
final class PiPTrace {
    private let url: URL
    private let began: TimeInterval
    private let clock: () -> TimeInterval
    private var data = Data()
    private var count = 0
    private var window: TimeInterval
    private var burst = 0
    private var omitted = 0
    private var ended = false

    init(url: URL, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.url = url
        self.clock = clock
        began = clock()
        window = began
    }

    func record(_ state: @autoclosure () -> String, throttle: Bool = false) {
        guard !ended else { return }
        let now = clock()
        if now - began > 600 || count >= 512 || data.count >= 120_000 {
            ended = true
            append("END budget reached; omitted=\(omitted); later events NOT recorded\n")
            return
        }
        if now - window >= 1 { window = now; burst = 0 }
        if throttle {
            guard burst < 8 else { omitted += 1; return }
            burst += 1
        }
        count += 1
        let line = "\(count) wall=\(Date().timeIntervalSince1970) up=\(now) omitted=\(omitted) \(state().prefix(1500))\n"
        omitted = 0
        append(line)
    }

    private func append(_ line: String) {
        data.append(contentsOf: line.utf8)
        try? data.write(to: url, options: .atomic)
    }
}
