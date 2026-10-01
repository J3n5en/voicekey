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
            } footer: {
                Text("在任意输入框中长按快捷键说话，松开后识别结果自动粘贴到光标处。")
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
        }
    }

    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
