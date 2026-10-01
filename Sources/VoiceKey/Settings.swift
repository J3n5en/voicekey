import AppKit
import AVFoundation
import SwiftUI

enum Channel: String, CaseIterable, Identifiable {
    case doubao, wetype
    var id: String { rawValue }
    var title: String { self == .doubao ? "豆包输入法" : "微信输入法" }
    static var current: Channel { Channel(rawValue: UserDefaults.standard.string(forKey: "channel") ?? "") ?? .doubao }
}

enum Hotkey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn
    var id: String { rawValue }
    static var current: Hotkey { Hotkey(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .rightOption }
    /// 点按模式下静音多久自动结束
    static var silence: Double { UserDefaults.standard.object(forKey: "silence") as? Double ?? 1.5 }

    var title: String {
        switch self {
        case .rightOption: "右 Option ⌥"
        case .rightCommand: "右 Command ⌘"
        case .rightControl: "右 Control ⌃"
        case .fn: "Fn 🌐"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .fn: 63
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        case .fn: .maskSecondaryFn
        }
    }
}

/// 用户录制的点按快捷键：单个修饰键（区分左右）或 修饰键+按键 组合
struct Shortcut: Equatable {
    var keyCode: Int64
    var modifiers: UInt64
    var name: String

    static let mask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    static let modifierFlag: [Int64: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand, 58: .maskAlternate, 61: .maskAlternate,
        59: .maskControl, 62: .maskControl, 56: .maskShift, 60: .maskShift, 63: .maskSecondaryFn,
    ]
    static let modifierName: [Int64: String] = [
        54: "右 ⌘", 55: "左 ⌘", 58: "左 ⌥", 61: "右 ⌥", 59: "左 ⌃", 62: "右 ⌃", 56: "左 ⇧", 60: "右 ⇧", 63: "Fn",
    ]
    /// 不带修饰键也允许单独使用的键（F1–F20）
    static let functionKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    private static let specialNames: [Int64: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    var isModifier: Bool { Self.modifierFlag[keyCode] != nil }

    var title: String {
        let f = CGEventFlags(rawValue: modifiers)
        var t = ""
        if f.contains(.maskControl) { t += "⌃" }
        if f.contains(.maskAlternate) { t += "⌥" }
        if f.contains(.maskShift) { t += "⇧" }
        if f.contains(.maskCommand) { t += "⌘" }
        return t + name
    }

    var raw: String { "\(keyCode),\(modifiers),\(name)" }

    init(keyCode: Int64, modifiers: UInt64, name: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.name = name
    }

    init?(raw: String) {
        let parts = raw.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = Int64(parts[0]), let mods = UInt64(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: mods, name: String(parts[2]))
    }

    static func keyName(_ code: Int64, _ chars: String?) -> String {
        specialNames[code] ?? modifierName[code] ?? (chars?.uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(code)"
    }

    static let defaultRaw = Shortcut(keyCode: 54, modifiers: 0, name: "右 ⌘").raw

    /// "off" 表示关闭；按原始字符串缓存，事件回调里频繁读取
    private static var cache: (String, Shortcut?) = ("", nil)
    static var tap: Shortcut? {
        let raw = UserDefaults.standard.string(forKey: "tapShortcut") ?? defaultRaw
        if cache.0 != raw { cache = (raw, Shortcut(raw: raw)) }
        return cache.1
    }
}

/// 点击后录制下一次按键：单独点按一个修饰键，或按下 修饰键+键；Esc 取消
struct ShortcutField: View {
    @Binding var raw: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifier: Int64?

    var body: some View {
        HStack {
            Button(recording ? "请按下快捷键…（Esc 取消）" : (Shortcut(raw: raw)?.title ?? "未设置")) {
                recording ? stop() : start()
            }
            if !recording, raw != "off" {
                Button { raw = "off" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("关闭点按快捷键")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        pendingModifier = nil
        HotkeyMonitor.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            handle(e)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotkeyMonitor.paused = false
    }

    private func handle(_ e: NSEvent) {
        guard let cg = e.cgEvent else { return }
        let code = Int64(e.keyCode)
        let mods = cg.flags.intersection(Shortcut.mask).rawValue
        if e.type == .keyDown {
            if code == 53, mods == 0 { return stop() }
            guard mods != 0 || Shortcut.functionKeys.contains(code) else { return NSSound.beep() }
            raw = Shortcut(keyCode: code, modifiers: mods, name: Shortcut.keyName(code, e.charactersIgnoringModifiers)).raw
            return stop()
        }
        guard let flag = Shortcut.modifierFlag[code] else { return }
        if cg.flags.contains(flag) {
            // 同时按了多个修饰键则不作为单键录入，等待后续组合键
            pendingModifier = pendingModifier == nil ? code : -1
        } else {
            if pendingModifier == code {
                raw = Shortcut(keyCode: code, modifiers: 0, name: Shortcut.modifierName[code]!).raw
                return stop()
            }
            if cg.flags.intersection(Shortcut.mask.union(.maskSecondaryFn)).isEmpty { pendingModifier = nil }
        }
    }
}

struct SettingsView: View {
    @AppStorage("channel") private var channel = Channel.doubao.rawValue
    @AppStorage("hotkey") private var hotkey = Hotkey.rightOption.rawValue
    @AppStorage("tapShortcut") private var tapShortcut = Shortcut.defaultRaw
    @AppStorage("silence") private var silence = 1.5
    @AppStorage("streaming") private var streaming = true
    @AppStorage("micUID") private var micUID = ""
    @State private var microphones = Microphone.all()
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Picker("识别渠道", selection: $channel) {
                    ForEach(Channel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Picker("长按快捷键", selection: $hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("点按快捷键") { ShortcutField(raw: $tapShortcut) }
                if tapShortcut != "off" {
                    Picker("静音自动结束", selection: $silence) {
                        ForEach([1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) { Text("\($0, specifier: "%g") 秒").tag($0) }
                    }
                }
                Toggle("边说边上屏", isOn: $streaming)
                Picker("麦克风", selection: $micUID) {
                    Text("系统默认").tag("")
                    ForEach(microphones) { Text($0.name).tag($0.id) }
                    if !micUID.isEmpty, !microphones.contains(where: { $0.id == micUID }) {
                        Text("已断开（暂用系统默认）").tag(micUID)
                    }
                }
            } footer: {
                Text((streaming ? "在任意输入框中长按快捷键说话，识别结果实时打到光标处，松开后按定稿修正。"
                                : "在任意输入框中长按快捷键说话，松开后识别结果粘贴到光标处。")
                     + (tapShortcut == "off" ? "" : "\n或点按一下点按快捷键开始聆听，停顿 \(String(format: "%g", silence)) 秒自动结束，再点一下可提前结束。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("权限") {
                LabeledContent("辅助功能（监听快捷键、粘贴）") {
                    if axTrusted {
                        Text("已授权").foregroundStyle(.green)
                    } else {
                        Button("去授权") { openPrivacy("Privacy_Accessibility") }
                    }
                }
                LabeledContent("麦克风") {
                    switch micStatus {
                    case .authorized: Text("已授权").foregroundStyle(.green)
                    case .notDetermined: Button("请求授权") { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
                    default: Button("去授权") { openPrivacy("Privacy_Microphone") }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .onReceive(timer) { _ in
            axTrusted = AXIsProcessTrusted()
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let now = Microphone.all()
            if now != microphones { microphones = now }
        }
    }

    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
