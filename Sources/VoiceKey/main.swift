import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--test"), i + 2 < args.count {
    // VoiceKey --test doubao|wetype file.wav [--type]（--type：流式打到当前焦点输入框）
    let engine: ASREngine = args[i + 1] == "wetype" ? WeTypeEngine() : DoubaoEngine()
    let url = URL(fileURLWithPath: args[i + 2])
    let typer = args.contains("--type") ? StreamTyper() : nil
    Task {
        do {
            let start = Date()
            let text = try await engine.run(audio: try fileFrames(url, realtime: true)) { partial in
                print("…", partial)
                DispatchQueue.main.async { typer?.update(partial) }
            }
            await MainActor.run { if !text.isEmpty { typer?.update(text) } }
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
