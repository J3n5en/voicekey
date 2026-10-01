import AppKit
import CHanbao

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--offline-worker" {
    // 离线识别子进程：stdin/stdout JSON-lines，由 OfflineWorker 拉起
    var argv: [UnsafeMutablePointer<CChar>?] = ["VoiceKey", "--pipe", args[2]].map { (s: String) in strdup(s) } + [nil]
    exit(hanbao_main(3, &argv))
}
signal(SIGPIPE, SIG_IGN) // 离线子进程退出后写管道不应杀死主进程

if let i = args.firstIndex(of: "--test"), i + 2 < args.count {
    // VoiceKey --test doubao|wetype|offline file.wav [--type]（--type：流式打到当前焦点输入框）
    let engine: ASREngine = switch args[i + 1] {
    case "wetype": WeTypeEngine()
    case "offline": OfflineEngine()
    case "qwen": QwenEngine()
    default: DoubaoEngine()
    }
    let url = URL(fileURLWithPath: args[i + 2])
    let typer = args.contains("--type") ? StreamTyper() : nil
    Task {
        do {
            if engine is OfflineEngine, !OfflineAssets.installed { try await OfflineAssets.shared.install() }
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
