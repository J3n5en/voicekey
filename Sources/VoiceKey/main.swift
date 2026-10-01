import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--test"), i + 2 < args.count {
    // VoiceKey --test doubao|wetype file.wav
    let engine: ASREngine = args[i + 1] == "wetype" ? WeTypeEngine() : DoubaoEngine()
    let url = URL(fileURLWithPath: args[i + 2])
    Task {
        do {
            let start = Date()
            let text = try await engine.run(audio: try fileFrames(url, realtime: true)) { print("…", $0) }
            print("FINAL:", text, String(format: "(%.2fs)", Date().timeIntervalSince(start)))
            exit(0)
        } catch {
            print("ERROR:", error.localizedDescription)
            exit(1)
        }
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
