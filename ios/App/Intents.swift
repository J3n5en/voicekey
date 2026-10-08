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
        "当前没有在用 VoiceKey 键盘：先点一个输入框并切到 VoiceKey，再按。"
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
    private static var waiting: CheckedContinuation<Bool, Never>?
    private static var observing = false

    static func fire(timeout: Double = 0.8) async -> Bool {
        if !observing {
            observing = true
            Bus.observe(VK.Note.hotkeyAck) { Hotkey.finish(true) }
        }
        finish(false)
        Bus.write(VK.now, VK.File.hotkey)
        return await withCheckedContinuation { c in
            waiting = c
            Bus.post(VK.Note.hotkey)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { Hotkey.finish(false) }
        }
    }

    private static func finish(_ ok: Bool) {
        waiting?.resume(returning: ok)
        waiting = nil
    }
}
