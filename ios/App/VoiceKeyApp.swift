import SwiftUI

@main
struct VoiceKeyApp: App {
    @StateObject private var session = SessionManager.shared
    @StateObject private var perms = Permissions.shared
    @StateObject private var tests = ChannelTest.shared

    init() {
        Bus.log("launch args=\(ProcessInfo.processInfo.arguments.dropFirst()) group=\(Bus.root?.path ?? "nil")")
        // 无人值守验证：-arm 开会话；-selftest 跑全部渠道；-script 按键盘方式发命令（见 Testing.swift）
        if Launch.has("-onboarded") { UserDefaults.standard.set(true, forKey: "onboarded") }
        if let ids = Launch.value("-enable")?.split(separator: ",").map(String.init) {
            for i in SessionManager.shared.config.channels.indices { SessionManager.shared.config.channels[i].on = ids.contains(SessionManager.shared.config.channels[i].id) }
        }
        if let m = Launch.value("-multi") { SessionManager.shared.config.multi = m == "1" }
        // -standby pip|mic：待机方式
        if let s = Launch.value("-standby").flatMap(Standby.init(rawValue:)) { SessionManager.shared.config.standby = s }
        // -typing t9,metrics：键盘布局与测试用耗时/内存显示
        if let t = Launch.value("-typing") {
            var p = TypingPrefs()
            p.t9 = t.contains("t9")
            p.metrics = t.contains("metrics")
            p.save()
        }
        if Launch.has("-arm") { SessionManager.shared.arm() }
        if Launch.has("-selftest") { Config.initial.channels.forEach { ChannelTest.shared.run($0) } }
        if let s = Launch.value("-script") { Harness.run(s) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(perms)
                .environmentObject(tests)
                .tint(.accentVK)
                .onOpenURL(perform: open)
        }
    }

    /// voicekey://session?source=keyboard：键盘拉起开会话，开好后提示用户点左上角返回
    private func open(_ url: URL) {
        Bus.log("openURL \(url)")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        if q?.first(where: { $0.name == "source" })?.value == "keyboard" || url.host == "arm" {
            session.openedFromKeyboard = true
        }
        guard url.host == "session" || url.host == "arm" else { return }
        session.touch()
        switch perms.mic {
        case .granted: session.arm()
        case .undetermined: perms.requestMic { if $0 { session.arm() } }
        default: break
        }
    }
}
