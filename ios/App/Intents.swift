import AppIntents
import Foundation

/// 操作按钮 / 快捷指令：正在用 VoiceKey 键盘时开始说话，说话中再按一次结束
struct TalkIntent: AppIntent {
    static var title: LocalizedStringResource = "VoiceKey 说话"
    static var description = IntentDescription("正在用 VoiceKey 键盘打字时，切到语音并开始说话；说话中再运行一次结束这句。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await Hotkey.fire() else { throw HotkeyError.noKeyboard }
        return .result()
    }
}

enum HotkeyError: Error, CustomLocalizedStringResourceConvertible {
    case noKeyboard

    var localizedStringResource: LocalizedStringResource {
        "请先允许 VoiceKey 键盘完全访问，点一个输入框并切到 VoiceKey，再按。"
    }
}

struct VoiceKeyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkIntent(), phrases: ["用\(.applicationName)说话", "\(.applicationName)说话"],
                    shortTitle: "说话", systemImageName: "mic.fill")
    }
}

/// 发信号给正在显示的键盘，等它回 ack
@MainActor
enum Hotkey {
    private static var waiting: (id: String, continuation: CheckedContinuation<Bool, Never>)?
    private static var observing = false

    static func fire(timeout: Double = 0.8) async -> Bool {
        if !observing {
            observing = true
            Bus.observe(VK.Note.hotkeyAck) {
                guard let id = Bus.read(String.self, VK.File.hotkeyAck) else { return }
                Hotkey.finish(true, id: id)
            }
        }
        if let waiting { finish(false, id: waiting.id) }
        let request = HotkeyRequest()
        Bus.write(request, VK.File.hotkey)
        return await withCheckedContinuation { c in
            waiting = (request.id, c)
            Bus.post(VK.Note.hotkey)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { Hotkey.finish(false, id: request.id) }
        }
    }

    private static func finish(_ ok: Bool, id: String) {
        guard let waiting, waiting.id == id else { return }
        Self.waiting = nil
        waiting.continuation.resume(returning: ok)
    }
}
