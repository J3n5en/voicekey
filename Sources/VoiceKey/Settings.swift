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
    /// 点按开关聆听的键，"off" 关闭
    static var tap: Hotkey? { Hotkey(rawValue: UserDefaults.standard.string(forKey: "tapHotkey") ?? Hotkey.rightCommand.rawValue) }
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

struct SettingsView: View {
    @AppStorage("channel") private var channel = Channel.doubao.rawValue
    @AppStorage("hotkey") private var hotkey = Hotkey.rightOption.rawValue
    @AppStorage("tapHotkey") private var tapHotkey = Hotkey.rightCommand.rawValue
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
                Picker("点按快捷键", selection: $tapHotkey) {
                    Text("关闭").tag("off")
                    ForEach(Hotkey.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if tapHotkey != "off" {
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
                     + (tapHotkey == "off" ? "" : "\n或点按一下点按快捷键开始聆听，停顿 \(String(format: "%g", silence)) 秒自动结束，再点一下可提前结束。"))
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
