import SwiftUI

extension Color {
    static let accentVK = Color(red: 0x6a / 255, green: 0x5c / 255, blue: 0xff / 255)
    static let okVK = Color(red: 0x1f / 255, green: 0xb5 / 255, blue: 0x7a / 255)
    static let errVK = Color(red: 0xef / 255, green: 0x4a / 255, blue: 0x5a / 255)
}

let brandGradient = LinearGradient(colors: [Color(red: 0.13, green: 0.76, blue: 1), Color(red: 0.48, green: 0.36, blue: 1), Color(red: 1, green: 0.24, blue: 0.55)], startPoint: .leading, endPoint: .trailing)

func mmss(_ s: Double) -> String {
    let t = max(0, Int(s))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

struct Logo: View {
    var size: CGFloat
    var body: some View {
        HStack(spacing: size * 0.08) {
            ForEach([6, 14, 20, 12, 4] as [CGFloat], id: \.self) { h in
                Capsule().frame(width: size * 0.09, height: size * h / 32 + size * 0.09)
            }
        }
        .foregroundStyle(brandGradient)
        .frame(width: size, height: size)
    }
}

struct AppIconView: View {
    var body: some View {
        Logo(size: 56)
            .frame(width: 84, height: 84)
            .background(Color(red: 0.09, green: 0.1, blue: 0.18), in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(red: 0.16, green: 0.12, blue: 0.47).opacity(0.35), radius: 12, y: 8)
    }
}

struct Pill: View {
    var text: String
    var color: Color?
    var body: some View {
        Text(text).font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(color ?? .secondary)
            .background((color ?? .secondary).opacity(0.15), in: Capsule())
    }
}

struct Banner: View {
    var error = false
    var text: Text
    var action: (String, () -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(error ? Color.errVK : Color.accentVK)
            VStack(alignment: .leading, spacing: 4) {
                text.font(.subheadline)
                if let action { Button(action.0, action: action.1).font(.subheadline) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background((error ? Color.errVK : Color.accentVK).opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
}

// MARK: - 根视图

enum Tab { case session, channels, settings }

struct RootView: View {
    @EnvironmentObject var session: SessionManager
    @EnvironmentObject var perms: Permissions
    @AppStorage("onboarded") private var onboarded = false
    @State private var tab = Tab.session
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if !onboarded && !session.openedFromKeyboard {
                OnboardingView { onboarded = true }
            } else {
                TabView(selection: $tab) {
                    SessionView().tabItem { Label("会话", systemImage: "mic") }.tag(Tab.session)
                    ChannelsView().tabItem { Label("渠道", systemImage: "line.3.horizontal") }.tag(Tab.channels)
                    SettingsView { onboarded = false }.tabItem { Label("设置", systemImage: "gearshape") }.tag(Tab.settings)
                }
            }
        }
        .onChange(of: session.openedFromKeyboard) { _, v in if v { tab = .session } }
        .onChange(of: phase) { _, p in
            if p == .active { perms.refresh() }
            if p == .background { session.openedFromKeyboard = false }
        }
    }
}

// MARK: - 会话

struct SessionView: View {
    @EnvironmentObject var session: SessionManager
    @EnvironmentObject var perms: Permissions
    @State private var copied = false
    @AppStorage("pipHintSeen") private var pipHintSeen = false

    private var pipOn: Bool { session.active && session.standby == .pip }
    private var idleMode: Standby { session.active ? session.standby : session.config.standbyMode }

    var body: some View {
        NavigationStack {
            List {
                if session.openedFromKeyboard && session.active {
                    Banner(text: Text(pipOn
                        ? "会话已开启，VoiceKey 在后台待命，不占麦克风。点屏幕左上角的 **「◀ 原 App」** 回到输入框，点麦克风开始说话。"
                        : "会话已开启。点屏幕左上角的 **「◀ 原 App」** 回到刚才的输入框，再点一次麦克风开始说话。"))
                } else if pipOn && !pipHintSeen {
                    Banner(text: Text("VoiceKey 在后台待命，不占麦克风，点键盘麦克风才录音。在多任务里划掉 VoiceKey，待命就停了。"),
                           action: ("知道了", { pipHintSeen = true }))
                }
                if !perms.micGranted {
                    Banner(error: true, text: Text("需要麦克风权限才能开启会话。"),
                           action: (perms.mic == .denied ? "去设置开启" : "允许麦克风", { perms.requestMic { if $0 { session.arm() } } }))
                }
                Section { hero }
                Section {
                    Picker("待机方式", selection: Binding(get: { session.config.standbyMode }, set: { session.setStandby($0) })) {
                        Text("画中画待机（待机不占麦，推荐）").tag(Standby.pip)
                        Text("常开麦（响应最快）").tag(Standby.mic)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: { Text("待机方式") } footer: {
                    Text(session.config.standbyMode == .pip
                         ? "会话期间 VoiceKey 在后台待命，不占麦克风，点键盘麦克风才录音，说完马上关闭。在多任务里划掉 VoiceKey，待命就停了。"
                         : "会话期间一直开着麦克风，屏幕顶部持续显示录音指示。")
                }
                Section {
                    if idleMode == .pip {
                        LabeledContent("无操作自动结束", value: "不自动结束")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("无操作自动结束")
                            Picker("无操作自动结束", selection: $session.config.idleMinutes) {
                                ForEach(Config.idleChoices, id: \.self) { Text($0 == 0 ? "不自动" : "\($0) 分钟").tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                } header: { Text("会话") } footer: {
                    Text(idleMode == .pip
                         ? "画中画待机不因闲置自动结束；闲置时长仅适用于常开麦，原设置会保留。可手动结束会话，在多任务里划掉 VoiceKey 也会停止待命。"
                         : "结束会话后停止待命、关闭麦克风。快到时间时键盘里会提醒，说话会自动续期。")
                }
                Section {
                    if session.history.isEmpty {
                        Text("还没有记录。上屏失败或没插进去时，可以在这里找回。").foregroundStyle(.secondary).font(.subheadline)
                    }
                    ForEach(session.history) { h in
                        Button {
                            UIPasteboard.general.string = h.text
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(h.text).foregroundStyle(.primary)
                                    Text("\(Date(timeIntervalSince1970: h.at).formatted(date: .omitted, time: .shortened)) · \(h.channel)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("复制").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("最近上屏") }
            }
            .navigationTitle("会话")
            .overlay(alignment: .bottom) {
                if copied {
                    Text("已复制").padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
                }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: session.active ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(session.active ? .white : .secondary)
                    .frame(width: 46, height: 46)
                    .background {
                        if session.active { Circle().fill(brandGradient) } else { Circle().fill(Color.secondary.opacity(0.15)) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.active ? (session.interrupted ? "已暂停" : pipOn ? "画中画待命" : "会话中") : "未开启").font(.title3.bold())
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if session.active {
                Button { session.disarm(.user) } label: { Text("结束会话").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            } else {
                Button {
                    perms.requestMic { if $0 { session.arm() } }
                } label: { Text("开启会话").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(perms.mic == .denied)
            }
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        if session.active {
            if session.interrupted { return pipOn ? "被通话或其他 App 打断，结束后自动恢复" : "麦克风被通话或其他 App 占用，结束后自动恢复" }
            let m = pipOn ? 0 : session.config.idleMinutes
            let note = session.standby != session.config.standbyMode ? "画中画没能用，本次改为常开麦 · " : ""
            return note + "已保持 \(mmss(VK.now - (session.since ?? VK.now))) · " + (m > 0 ? "无操作 \(m) 分钟后自动结束" : "不会自动结束，需手动结束")
        }
        switch session.endReason {
        case .idle: return "因长时间无操作已自动结束。在键盘上点麦克风会重新开启"
        case .interrupted: return "被通话或其他 App 打断后未能恢复。点下面重新开启"
        case .pipClosed: return "后台待命已停止，会话随之结束。点下面重新开启"
        case .bgDenied: return "后台没能开麦，会话已结束。重新开启后本次改为常开麦"
        case .failed: return "麦克风启动失败，请稍后重试"
        default: return "在键盘上点麦克风会自动开启"
        }
    }
}

// MARK: - 渠道

struct ChannelList: View {
    @EnvironmentObject var session: SessionManager
    @EnvironmentObject var tests: ChannelTest
    var compact = false
    @State private var renaming: Channel?
    @State private var draft = ""

    var body: some View {
        ForEach(session.config.channels) { ch in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(ch.name)
                        Button { draft = ch.name; renaming = ch } label: { Image(systemName: "pencil").font(.footnote) }
                            .buttonStyle(.borderless).tint(.secondary)
                    }
                    if !compact {
                        Text("云端识别" + (tests.results[ch.id].map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !compact {
                    Button("测试") { tests.run(ch) }.buttonStyle(.borderless)
                }
                Toggle("", isOn: Binding(get: { ch.on }, set: { setOn(ch.id, $0) })).labelsHidden()
            }
            .alert("渠道显示名", isPresented: Binding(get: { renaming?.id == ch.id }, set: { if !$0 { renaming = nil } })) {
                TextField("渠道名", text: $draft)
                Button("取消", role: .cancel) {}
                Button("好") {
                    let n = String(draft.trimmingCharacters(in: .whitespaces).prefix(8))
                    if !n.isEmpty, let i = session.config.channels.firstIndex(where: { $0.id == ch.id }) {
                        session.config.channels[i].name = n
                    }
                }
            } message: { Text("最多 8 个字，只在 VoiceKey 里显示") }
        }
    }

    private func setOn(_ id: String, _ on: Bool) {
        var c = session.config
        guard let i = c.channels.firstIndex(where: { $0.id == id }) else { return }
        c.channels[i].on = on
        if !c.enabled.contains(where: { $0.id == c.defaultChannel }), let f = c.enabled.first { c.defaultChannel = f.id }
        session.config = c
    }
}

struct ChannelsView: View {
    @EnvironmentObject var session: SessionManager

    var body: some View {
        let enabled = session.config.enabled
        NavigationStack {
            List {
                Section { ChannelList() } footer: { Text("显示名可以自定义；界面只显示你起的名字。") }
                Section("多渠道") {
                    Toggle(isOn: Binding(get: { session.config.isMulti }, set: { session.config.multi = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("多渠道候选")
                            Text(enabled.count < 2 ? "至少打开 2 个渠道" : "同时识别，在键盘里选一条上屏；默认选中上次用的")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(enabled.count < 2)
                }
                Section("单渠道时使用") {
                    if enabled.isEmpty { Text("没有可用渠道").foregroundStyle(Color.errVK) }
                    ForEach(enabled) { ch in
                        HStack {
                            Text(ch.name)
                            Spacer()
                            Image(systemName: ch.id == session.config.defaultChannel ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(ch.id == session.config.defaultChannel ? Color.accentVK : .secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { session.config.defaultChannel = ch.id }
                    }
                }
            }
            .navigationTitle("渠道")
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var perms: Permissions
    @State private var typing = TypingPrefs.load()
    var reonboard: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("VoiceKey 键盘", ok: perms.keyboard, sub: "设置 › VoiceKey › 键盘") { Permissions.openSettings() }
                    row("允许完全访问", ok: perms.fullAccess, sub: perms.keyboard && !perms.fullAccess ? "开启后在任意输入框切到 VoiceKey 键盘一次即可检测到" : "键盘与主 App 通信、联网识别") { Permissions.openSettings() }
                    row("麦克风", ok: perms.micGranted, sub: "只在说话时收音") { perms.requestMic() }
                    if perms.cellularRestricted {
                        row("无线数据", ok: false, sub: "VoiceKey 需要联网识别") { Permissions.openSettings() }
                    }
                } header: { Text("权限") }
                Section {
                    Toggle("拼音显示在输入框里", isOn: $typing.inlinePinyin)
                        .onChange(of: typing.inlinePinyin) { typing.save() }
                    Picker("中文键盘", selection: $typing.t9) {
                        Text("26 键全拼").tag(false)
                        Text("九宫格").tag(true)
                    }
                    .onChange(of: typing.t9) { typing.save() }
                    Toggle("按键震动", isOn: $typing.haptics)
                        .onChange(of: typing.haptics) { typing.save() }
                    Toggle("显示按键耗时", isOn: $typing.metrics)
                        .onChange(of: typing.metrics) { typing.save() }
                } header: { Text("键盘") } footer: { Text("键盘顶部「26｜九键」随时切，切过就记住。按键震动需允许完全访问；按键耗时显示在键盘底部，排查卡顿用。") }
                Section("通用") {
                    Button("重新查看引导", action: reonboard)
                }
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")（TestFlight 内部测试）").foregroundStyle(.secondary)
                    }
                    NavigationLink("开源许可") { LicensesView() }
                }
            }
            .navigationTitle("设置")
            .onAppear { typing = TypingPrefs.load() }
        }
    }

    private func row(_ title: String, ok: Bool, sub: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ok { Pill(text: "已开启", color: .okVK) } else { Button("去开启", action: action).buttonStyle(.borderless) }
        }
    }
}

// MARK: - 首次引导

struct OnboardingView: View {
    @EnvironmentObject var perms: Permissions
    @EnvironmentObject var session: SessionManager
    var done: () -> Void
    /// 打开完全访问时系统会结束 App，回来要停在原步骤
    @AppStorage("onboardingStep") private var step = 0
    @State private var trying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<5) { i in
                    Capsule().fill(i == step ? Color.accentVK : Color.secondary.opacity(0.2)).frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }.frame(maxWidth: .infinity, alignment: .leading)
            }
            actions
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .background(Color(.systemGroupedBackground))
        .animation(.default, value: step)
        .sheet(isPresented: $trying) { TryView() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            VStack(spacing: 12) {
                AppIconView().padding(.top, 30).padding(.bottom, 10)
                Text("想说就说\n想打就打").font(.title.bold()).multilineTextAlignment(.center)
                Text("中文全拼 26 键或九宫格打字，点左上角麦克风就能说。勾选多个渠道时，可以在键盘里对比结果再选一条。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        case 1:
            title("添加 VoiceKey 键盘", "在系统设置里打开下面两项，回来后这里会自动更新。")
            stepRow(perms.keyboard ? nil : "1", "添加键盘", "设置 › VoiceKey › 键盘 › 打开「VoiceKey」")
            stepRow(perms.fullAccess ? nil : "2", "允许完全访问", "用于语音和最近记录；没开启也能本地打字。普通打字不写入最近；主动清空的文字会保存在本机，方便恢复。")
            if perms.cellularRestricted {
                stepRow("!", "允许使用无线数据", "设置 › VoiceKey › 无线数据，选「WLAN 与蜂窝网络」，否则无法联网识别")
            }
            if !perms.fullAccess {
                // 完全访问只有键盘出现过才知道：在这里切到 VoiceKey，键盘一出现就打勾
                VStack(alignment: .leading, spacing: 8) {
                    Text(perms.keyboardSeen ? "已切到 VoiceKey，但完全访问还没打开。" : "打开后，在下面输入框里按住 🌐 切到「VoiceKey」，键盘一出现这里就会打勾。")
                        .font(.footnote).foregroundStyle(perms.keyboardSeen ? Color.errVK : .secondary)
                    ProbeField(placeholder: "点这里，切到 VoiceKey")
                        .frame(height: 22)
                        .padding(10)
                        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                .card()
            }
        case 2:
            title("允许使用麦克风", "iOS 不允许键盘直接录音，所以录音在 VoiceKey 主 App 里进行：在键盘上点麦克风时，主 App 在后台收音并把文字送回键盘。")
            HStack(alignment: .top, spacing: 12) {
                badge(perms.micGranted ? nil : "🎙")
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("麦克风")
                        switch perms.mic {
                        case .granted: Pill(text: "已允许", color: .okVK)
                        case .denied: Pill(text: "已拒绝", color: .errVK)
                        default: Pill(text: "未请求")
                        }
                    }
                    Text(perms.mic == .denied ? "已拒绝过，只能到系统设置里打开。" : "只在你点麦克风说话时收音；会话期间顶部会显示录音指示。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .card()
        case 3:
            title("选择识别渠道", "勾选 2 个以上会同时识别，在键盘里看着各渠道的结果选一条上屏。名字可以改。")
            VStack(spacing: 0) {
                ChannelList(compact: true)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider() }
            }
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 16)
        default:
            title("怎么用", nil)
            stepRow("1", "在任意 App 点输入框，按住 🌐 选「VoiceKey」", nil)
            stepRow("2", "打字，或点左上角麦克风", "默认中文 26 键全拼，键盘顶部「26｜九键」可切九宫格。空心麦克风会先跳到 VoiceKey 开会话，再点左上角「◀」回到原 App。")
            stepRow("3", "说完上屏，回到打字", "会话就绪时点麦克风直接开始说，再点结束。多渠道时选一条上屏；⌨ 返回打字。")
            stepRow("4", "VoiceKey 在后台待命", "开会话后 VoiceKey 在后台待命，不占麦克风，点麦克风才录音。在多任务里划掉 VoiceKey，待命就停了。")
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 10) {
            switch step {
            case 0:
                primary("开始设置（约 1 分钟）") {
                    Permissions.pokeNetwork()
                    step = 1
                }
            case 1:
                if perms.keyboard && perms.fullAccess {
                    primary("下一步") { step = 2 }
                } else {
                    // 检测不到也不拦人：只提示，「下一步」一直能点
                    Text("还没检测到\(perms.keyboard ? "完全访问" : "键盘")，可以先继续，之后在「设置」里查看。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    primary("前往设置") { Permissions.openSettings() }
                    Button("下一步") { step = 2 }
                }
            case 2:
                if perms.micGranted {
                    primary("下一步") { step = 3 }
                } else {
                    primary(perms.mic == .denied ? "去设置开启" : "允许麦克风") { perms.requestMic() }
                    Button("下一步") { step = 3 }
                }
            case 3:
                primary("下一步") { step = 4 }.disabled(session.config.enabled.isEmpty)
            default:
                primary("去试一试") { trying = true }
                Button("完成") {
                    step = 0
                    done()
                }
            }
        }
        .padding(.top, 12)
    }

    private func primary(_ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Text(t).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.borderedProminent).controlSize(.large)
    }

    @ViewBuilder private func title(_ t: String, _ sub: String?) -> some View {
        Text(t).font(.title2.bold()).padding(.bottom, 8)
        if let sub { Text(sub).foregroundStyle(.secondary) }
    }

    private func badge(_ n: String?) -> some View {
        Text(n ?? "✓").font(.footnote.weight(.semibold))
            .foregroundStyle(n == nil ? .white : .primary)
            .frame(width: 24, height: 24)
            .background(n == nil ? Color.okVK : Color.secondary.opacity(0.15), in: Circle())
    }

    private func stepRow(_ n: String?, _ t: String, _ sub: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            badge(n)
            VStack(alignment: .leading, spacing: 2) {
                Text(t)
                if let sub { Text(sub).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .card()
    }
}

private extension View {
    func card() -> some View {
        padding(.vertical, 12).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 10)
    }
}

/// 引导里检测键盘的输入框：切到 VoiceKey 时上报（没开完全访问的键盘自己传不出消息）
private struct ProbeField: UIViewRepresentable {
    let placeholder: String

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.placeholder = placeholder
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.tokens = [UITextInputMode.currentInputModeDidChangeNotification, UIResponder.keyboardDidShowNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak f] _ in
                guard let f, f.isFirstResponder, f.textInputMode?.vkID == VK.keyboardBundleID else { return }
                Permissions.shared.keyboardShown()
            }
        }
        return f
    }

    func updateUIView(_ v: UITextField, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ v: UITextField, coordinator: Coordinator) {
        coordinator.tokens.forEach(NotificationCenter.default.removeObserver)
    }

    final class Coordinator { var tokens: [NSObjectProtocol] = [] }
}

/// 引导里的试用输入框
struct TryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("点输入框，按住键盘左下角 🌐 切到「VoiceKey」，再点麦克风说一句。").foregroundStyle(.secondary)
                TextField("在这里试试", text: $text, axis: .vertical)
                    .lineLimit(4...8)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .focused($focused)
                Spacer()
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("试一试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .onAppear { focused = true }
        }
    }
}
