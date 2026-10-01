import AppKit
import AVFoundation
import SwiftUI

enum Channel: String, CaseIterable, Identifiable {
    case doubao, wetype, qwen, offline, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .doubao: "豆包输入法"
        case .wetype: "微信输入法"
        case .qwen: "千问输入法"
        case .offline: "离线（本地模型）"
        case .all: "全部"
        }
    }
    /// 离线渠道仅 Apple 芯片可用
    static var engines: [Channel] {
        OfflineAssets.supported ? [.doubao, .wetype, .qwen, .offline] : [.doubao, .wetype, .qwen]
    }
    static var available: [Channel] { engines + [.all] }
    static var current: Channel {
        let c = Channel(rawValue: UserDefaults.standard.string(forKey: "channel") ?? "") ?? .doubao
        return available.contains(c) ? c : .doubao
    }
}

enum QwenOutput: String, CaseIterable, Identifiable {
    case asr, polish, translate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .asr: "原文"
        case .polish: "润色"
        case .translate: "译成英文"
        }
    }
    static var current: QwenOutput {
        let raw = ProcessInfo.processInfo.environment["QWEN_OUTPUT"]
            ?? UserDefaults.standard.string(forKey: "qwenOutput")
            ?? ""
        return QwenOutput(rawValue: raw) ?? .polish
    }
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
    @AppStorage("qwenOutput") private var qwenOutput = QwenOutput.polish.rawValue
    @State private var microphones = Microphone.all()
    @ObservedObject private var offline = OfflineAssets.shared
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @StateObject private var compare = ChannelCompare()
    @State private var showCompare = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("识别渠道")
                    Spacer()
                    Button("对比") { showCompare = true }
                        .buttonStyle(.borderless)
                }
                Picker("", selection: $channel) {
                    ForEach(Channel.available) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: channel) { if $1 == Channel.offline.rawValue { offline.download() } }
                if channel == Channel.offline.rawValue { OfflineStatus(offline: offline) }
                if channel == Channel.qwen.rawValue || channel == Channel.all.rawValue {
                    Picker("千问输出", selection: $qwenOutput) {
                        ForEach(QwenOutput.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
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
                    .disabled(channel == Channel.all.rawValue)
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
                     + (tapShortcut == "off" ? "" : "\n或点按一下点按快捷键开始聆听，停顿 \(String(format: "%g", silence)) 秒自动结束，再点一下可提前结束。")
                     + (channel == Channel.all.rawValue ? "\n说完后在输入框上方列出各渠道结果，点击或 ↑↓ 回车上屏。" : ""))
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
        .onDisappear { compare.cancel() }
        .sheet(isPresented: $showCompare) {
            ChannelCompareSheet(channel: $channel, compare: compare)
        }
    }

    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

/// 离线模型下载状态
struct OfflineStatus: View {
    @ObservedObject var offline: OfflineAssets

    var body: some View {
        LabeledContent("离线模型（约 190MB）") {
            switch offline.state {
            case .ready: Text("已就绪").foregroundStyle(.green)
            case .downloading(let p):
                HStack { ProgressView(value: p).frame(width: 120); Text("\(Int(p * 100))%").monospacedDigit() }
            case .missing: Button("下载") { offline.download() }
            case .failed(let msg):
                HStack {
                    Text(msg).foregroundStyle(.red).lineLimit(1)
                    Button("重试") { offline.download() }
                }
            }
        }
    }
}

struct ChannelCompareSheet: View {
    @Binding var channel: String
    @ObservedObject var compare: ChannelCompare
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("渠道对比").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.borderless)
            }
            Button(compare.phase == .recording ? "说完了" : compare.phase == .recognizing ? "取消识别" : "开始说话") {
                compare.toggle()
            }
            if compare.phase == .recording {
                Text("正在录音，说完再点一次").font(.caption).foregroundStyle(.secondary)
            } else if compare.phase == .recognizing {
                Text("识别中…").font(.caption).foregroundStyle(.secondary)
            }
            if let err = compare.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            ForEach(compare.rows) { row in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.channel.title)
                        if !row.text.isEmpty {
                            Text(row.text).font(.caption).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(row.status).foregroundStyle(.secondary).font(.caption)
                    if compare.phase == .idle {
                        Button("选择") {
                            channel = row.channel.rawValue
                            dismiss()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, height: 360)
        .onDisappear { compare.cancel() }
    }
}

/// 设置里录音一次，各渠道并行识别并实时出字
@MainActor
final class ChannelCompare: ObservableObject {
    enum Phase { case idle, recording, recognizing }
    struct Row: Identifiable {
        var id: String { channel.rawValue }
        let channel: Channel
        var text = ""
        var status = ""
    }

    @Published var phase = Phase.idle
    @Published var rows: [Row] = []
    @Published var error: String?

    private let recorder = Recorder()
    private let doubao = DoubaoEngine()
    private let wetype = WeTypeEngine()
    private let qwen = QwenEngine()
    private let offline = OfflineEngine()
    private var work: Task<Void, Never>?

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stopRecord()
        case .recognizing: cancel()
        }
    }

    func cancel() {
        if phase == .recording { recorder.stop() }
        work?.cancel()
        work = nil
        HotkeyMonitor.paused = false
        phase = .idle
    }

    private func start() {
        error = nil
        rows = Channel.engines.map { ch in
            if ch == .offline, !OfflineAssets.installed {
                return Row(channel: ch, status: "跳过（未下载）")
            }
            return Row(channel: ch, status: "识别中")
        }
        let active = rows.filter { $0.status == "识别中" }.map(\.channel)
        HotkeyMonitor.paused = true
        do {
            let source = try recorder.start()
            phase = .recording
            wetype.prewarm()
            qwen.prewarm()
            if active.contains(.offline) { OfflineWorker.shared.prewarm() }
            let streams = Self.fanout(source, n: active.count)
            work = Task { await run(active, streams) }
        } catch {
            HotkeyMonitor.paused = false
            phase = .idle
            self.error = error.localizedDescription
        }
    }

    private func stopRecord() {
        guard phase == .recording else { return }
        recorder.stop()
        phase = .recognizing
    }

    private func run(_ channels: [Channel], _ streams: [AsyncStream<[Int16]>]) async {
        await withTaskGroup(of: Void.self) { g in
            for (i, ch) in channels.enumerated() {
                let stream = streams[i]
                g.addTask { await self.recognize(ch, stream) }
            }
        }
        HotkeyMonitor.paused = false
        phase = .idle
        work = nil
    }

    private func recognize(_ ch: Channel, _ stream: AsyncStream<[Int16]>) async {
        let engine: ASREngine = switch ch {
        case .doubao: doubao
        case .wetype: wetype
        case .qwen: qwen
        case .offline: offline
        case .all: doubao
        }
        let t0 = Date()
        do {
            let text = try await engine.run(audio: stream) { [weak self] p in
                Task { @MainActor in self?.set(ch, text: p) }
            }
            let sec = String(format: "%.2fs", Date().timeIntervalSince(t0))
            set(ch, text: text, status: sec)
        } catch is CancellationError {
            set(ch, status: "已取消")
        } catch {
            set(ch, status: error.localizedDescription)
        }
    }

    private func set(_ ch: Channel, text: String? = nil, status: String? = nil) {
        guard let i = rows.firstIndex(where: { $0.channel == ch }) else { return }
        if let text { rows[i].text = text }
        if let status { rows[i].status = status }
    }

    nonisolated static func fanout(_ source: AsyncStream<[Int16]>, n: Int) -> [AsyncStream<[Int16]>] {
        var conts: [AsyncStream<[Int16]>.Continuation] = []
        var streams: [AsyncStream<[Int16]>] = []
        for _ in 0..<n {
            let (s, c) = AsyncStream<[Int16]>.makeStream()
            streams.append(s)
            conts.append(c)
        }
        Task {
            for await frame in source {
                for c in conts { c.yield(frame) }
            }
            for c in conts { c.finish() }
        }
        return streams
    }
}
