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
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("静音自动结束", value: String(format: "%g 秒", session.config.silenceSeconds))
                        Slider(value: Binding(get: { session.config.silenceSeconds }, set: { session.config.silence = $0 }), in: 1...5, step: 0.5)
                    }
                } footer: { Text("点键盘麦克风开始说话后，停顿超过这个时长视为说完、自动结束。") }
                Section {
                    NavigationLink { HistoryView() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentVK).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("最近上屏")
                                Text(session.history.first?.text ?? "上屏失败或没插进去时，可以在这里找回")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if !session.history.isEmpty {
                                Text("\(session.history.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("会话")
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

// MARK: - 最近上屏

struct HistoryView: View {
    @EnvironmentObject var session: SessionManager
    @State private var query = ""
    @State private var copied = false
    @State private var confirmClear = false

    private var days: [(day: Date, items: [HistoryItem])] {
        let items = query.isEmpty ? session.history : session.history.filter { $0.text.localizedCaseInsensitiveContains(query) }
        let cal = Calendar.current
        return Dictionary(grouping: items) { cal.startOfDay(for: Date(timeIntervalSince1970: $0.at)) }
            .map { ($0.key, $0.value.sorted { $0.at > $1.at }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        // 空列表时不挂 List / 搜索栏：空 List 上的搜索栏推入后会收起一次，整页跟着跳
        Group {
            if session.history.isEmpty {
                ContentUnavailableView("还没有记录", systemImage: "clock.arrow.circlepath", description: Text("语音上屏的结果和键盘里主动清空的文字会保存在本机，上屏失败或没插进去时可以在这里找回。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            } else {
                List {
                    ForEach(days, id: \.day) { group in
                        Section(dayTitle(group.day)) {
                            ForEach(group.items) { row($0) }
                        }
                    }
                }
                .overlay { if days.isEmpty { ContentUnavailableView.search(text: query) } }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索")
            }
        }
        .navigationTitle("最近上屏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 常驻、空时置灰，避免按钮出现/消失让导航栏重排
            Button("清空", role: .destructive) { confirmClear = true }
                .disabled(session.history.isEmpty)
        }
        .confirmationDialog("清空全部最近上屏？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { session.clearHistory() }
        }
        .overlay(alignment: .bottom) {
            if copied {
                Label("已复制", systemImage: "checkmark").font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .onAppear { session.reloadHistory() }
    }

    private func row(_ h: HistoryItem) -> some View {
        Button { copy(h.text) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(h.text).foregroundStyle(.primary).lineLimit(4).multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(Date(timeIntervalSince1970: h.at).formatted(date: .omitted, time: .shortened))
                    Text(h.channel)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button("删除", role: .destructive) { session.removeHistory([h.id]) }
        }
        .contextMenu {
            Button { copy(h.text) } label: { Label("复制", systemImage: "doc.on.doc") }
            ShareLink(item: h.text) { Label("分享", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { session.removeHistory([h.id]) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
    }

    private func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        return d.formatted(.dateTime.month().day().weekday())
    }
}

// MARK: - 九宫格键位

/// 数字 1–9 与左侧标点列固定、不可交互；7 个功能键（⌫ 换行 回车 123 符 中/英 空格）可拖到右列或底行任意位置。
/// 拖动时像拼图：其他键实时让位、尺寸弹性重排，虚线框提示松手后的落点。按宽度自适应
struct T9LayoutView: View {
    @Binding var typing: TypingPrefs
    @State private var width: CGFloat = 0
    /// 正在拖的键、它的中心位置（跟手）、手指相对键中心的偏移、松手后的布局预览
    @State private var dragging: String?
    @State private var center: CGPoint = .zero
    @State private var grab: CGSize = .zero
    @State private var preview: T9Layout?

    private static let letters = ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ", "1": "@/."]
    private static let gap: CGFloat = 6

    /// 键宽按 5 列均分；键高约为键宽 0.6（同系统九宫格比例），限制在 40–60 之间
    private var col: CGFloat { max(0, (width - 4 * Self.gap) / 5) }
    private var rowH: CGFloat { min(60, max(40, col * 0.6)) }
    private var gridHeight: CGFloat { 4 * rowH + 3 * Self.gap }
    private var layout: T9Layout { typing.t9Layout }
    private var shown: T9Layout { preview ?? layout }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                grid
                    .frame(maxWidth: .infinity)
                    .frame(height: gridHeight)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                Text("按住功能键拖到右列或底行的任意位置，其他键会自动让位、调整大小，虚线框是松手后的位置。数字和标点列固定。「回车」在键盘上会随输入框显示为换行、发送、搜索等。改完下次弹出键盘生效。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                Button("恢复默认") { withAnimation(.snappy) { save(T9Layout()) } }
                    .disabled(layout == T9Layout())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
        }
        .scrollDisabled(dragging != nil)
        .background(Color(.systemGroupedBackground))
        .sensoryFeedback(.selection, trigger: preview)
        .navigationTitle("九宫格键位")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func frame(_ c: Double, _ r: Double, _ cw: Double = 1, _ rh: Double = 1) -> CGRect {
        CGRect(x: c * (col + Self.gap), y: r * (rowH + Self.gap),
               width: cw * col + (cw - 1) * Self.gap, height: rh * rowH + (rh - 1) * Self.gap)
    }

    private func frame(_ cell: T9Layout.Cell) -> CGRect { frame(cell.c, cell.r, cell.cw, cell.rh) }

    private var grid: some View {
        ZStack(alignment: .topLeading) {
            punct(frame(0, 0, 1, 3))
            ForEach(1...9, id: \.self) { n in digit(n, frame(Double((n - 1) % 3 + 1), Double((n - 1) / 3))) }
            // 落点提示：拖动中的键在预览布局里的位置
            if let dragging, let cell = shown.cells.first(where: { $0.id == dragging }) {
                let f = frame(cell)
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentVK, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentVK.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .frame(width: f.width, height: f.height)
                    .position(x: f.midX, y: f.midY)
                    .allowsHitTesting(false)
            }
            // 以键为身份：重排时各键从旧位置、旧尺寸动画到新的
            ForEach(shown.cells, id: \.id) { key($0) }
        }
        .frame(width: width, height: gridHeight, alignment: .topLeading)
        .coordinateSpace(name: "t9")
    }

    private func punct(_ f: CGRect) -> some View {
        VStack(spacing: 0) {
            ForEach(T9Layout.punct, id: \.self) { Text($0).frame(maxHeight: .infinity) }
        }
        .font(.subheadline).foregroundStyle(.tertiary)
        .frame(width: f.width, height: f.height)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .position(x: f.midX, y: f.midY)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("标点列（固定）")
    }

    private func digit(_ n: Int, _ f: CGRect) -> some View {
        VStack(spacing: 0) {
            Text("\(n)").font(.title3)
            if let l = Self.letters["\(n)"] { Text(l).font(.caption2) }
        }
        .foregroundStyle(.tertiary)
        .frame(width: f.width, height: f.height)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .position(x: f.midX, y: f.midY)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n)（固定）")
    }

    private func key(_ cell: T9Layout.Cell) -> some View {
        let f = frame(cell), id = cell.id, lifted = dragging == id
        return Text(T9Layout.name(id)).font(id.count == 1 ? .title3 : .subheadline)
            .foregroundStyle(.primary)
            .frame(width: f.width, height: f.height)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(lifted ? Color.accentVK : Color.secondary.opacity(0.3), lineWidth: lifted ? 2 : 0.5))
            .shadow(color: .black.opacity(lifted ? 0.25 : 0.08), radius: lifted ? 10 : 0.5, y: lifted ? 6 : 0.5)
            .scaleEffect(lifted ? 1.06 : 1)
            .opacity(lifted ? 0.92 : 1)
            .position(lifted ? center : CGPoint(x: f.midX, y: f.midY))
            .zIndex(lifted ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("t9"))
                    .onChanged { v in
                        if dragging == nil {
                            grab = CGSize(width: v.startLocation.x - f.midX, height: v.startLocation.y - f.midY)
                            center = CGPoint(x: f.midX, y: f.midY)
                            withAnimation(.snappy(duration: 0.15)) { dragging = id }
                        }
                        center = CGPoint(x: v.location.x - grab.width, y: v.location.y - grab.height)
                        let next = layout.dropping(id, x: v.location.x / (col + Self.gap), y: v.location.y / (rowH + Self.gap))
                        if next != preview { withAnimation(.snappy(duration: 0.25)) { preview = next } }
                    }
                    .onEnded { _ in
                        withAnimation(.snappy) {
                            if let preview { save(preview) }
                            dragging = nil
                            preview = nil
                        }
                    }
            )
            .accessibilityLabel(T9Layout.name(id))
            .accessibilityHint("拖到右列或底行调整位置")
    }

    private func save(_ l: T9Layout) {
        typing.t9Layout = l
        typing.save()
    }
}

// MARK: - 26 键键位

/// 字母固定、不可交互；第三行右端的键与底行的 ⌫ 123 中/英 ， 。 空格 回车 可拖动：底行内重排，与第三行右端互换。
/// 拖动时其他键实时让位，虚线框提示松手后的落点。按宽度自适应
struct QwertyLayoutView: View {
    @Binding var typing: TypingPrefs
    @State private var width: CGFloat = 0
    @State private var dragging: String?
    @State private var center: CGPoint = .zero
    @State private var grab: CGSize = .zero
    @State private var preview: QwertyLayout?

    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let gap: CGFloat = 5
    private static let vgap: CGFloat = 10

    /// 一格 = 字母键宽 + 键距，整行 10 格
    private var slot: CGFloat { max(0, (width + Self.gap) / 10) }
    private var rowH: CGFloat { min(52, max(36, slot * 1.25)) }
    private var gridHeight: CGFloat { 4 * rowH + 3 * Self.vgap }
    private var layout: QwertyLayout { typing.qwerty }
    private var shown: QwertyLayout { preview ?? layout }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                grid
                    .frame(maxWidth: .infinity)
                    .frame(height: gridHeight)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                Text("按住功能键拖动：在底行里左右调整顺序，拖到第三行右端（默认是删除键）或从那里拖下来就两键互换，空格会自动占满剩余宽度。字母固定。数字、符号页沿用同样的位置。改完下次弹出键盘生效。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                Button("恢复默认") { withAnimation(.snappy) { save(QwertyLayout()) } }
                    .disabled(layout == QwertyLayout())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
        }
        .scrollDisabled(dragging != nil)
        .background(Color(.systemGroupedBackground))
        .sensoryFeedback(.selection, trigger: preview)
        .navigationTitle("26 键键位")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func frame(_ x: Double, _ r: Int, _ w: Double = 1) -> CGRect {
        CGRect(x: x * slot, y: CGFloat(r) * (rowH + Self.vgap), width: w * slot - Self.gap, height: rowH)
    }

    private func cells(_ l: QwertyLayout) -> [(id: String, f: CGRect)] {
        let side = QwertyLayout.width("back")
        return [(l.side, frame(10 - side, 2, side))] + l.bottomCells.map { ($0.id, frame($0.x, 3, $0.w)) }
    }

    private var grid: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.rows.enumerated()), id: \.offset) { r, letters in
                let x0 = Double(10 - letters.count) / 2
                ForEach(Array(letters.enumerated()), id: \.offset) { i, c in fixed(String(c), frame(x0 + Double(i), r)) }
            }
            fixed("⇧", frame(0, 2, QwertyLayout.width("back")))
            if let dragging, let f = cells(shown).first(where: { $0.id == dragging })?.f {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentVK, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentVK.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .frame(width: f.width, height: f.height)
                    .position(x: f.midX, y: f.midY)
                    .allowsHitTesting(false)
            }
            ForEach(cells(shown), id: \.id) { key($0.id, $0.f) }
        }
        .frame(width: width, height: gridHeight, alignment: .topLeading)
        .coordinateSpace(name: "qwerty")
    }

    private func fixed(_ text: String, _ f: CGRect) -> some View {
        Text(text).font(.body)
            .foregroundStyle(.tertiary)
            .frame(width: f.width, height: f.height)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            .position(x: f.midX, y: f.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func key(_ id: String, _ f: CGRect) -> some View {
        let lifted = dragging == id
        return Text(QwertyLayout.name(id)).font(id.count <= 3 ? .body : .subheadline)
            .lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(.primary)
            .frame(width: f.width, height: f.height)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(lifted ? Color.accentVK : Color.secondary.opacity(0.3), lineWidth: lifted ? 2 : 0.5))
            .shadow(color: .black.opacity(lifted ? 0.25 : 0.08), radius: lifted ? 10 : 0.5, y: lifted ? 6 : 0.5)
            .scaleEffect(lifted ? 1.06 : 1)
            .opacity(lifted ? 0.92 : 1)
            .position(lifted ? center : CGPoint(x: f.midX, y: f.midY))
            .zIndex(lifted ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("qwerty"))
                    .onChanged { v in
                        if dragging == nil {
                            grab = CGSize(width: v.startLocation.x - f.midX, height: v.startLocation.y - f.midY)
                            center = CGPoint(x: f.midX, y: f.midY)
                            withAnimation(.snappy(duration: 0.15)) { dragging = id }
                        }
                        center = CGPoint(x: v.location.x - grab.width, y: v.location.y - grab.height)
                        let next = layout.dropping(id, x: v.location.x / slot, y: v.location.y / (rowH + Self.vgap))
                        if next != preview { withAnimation(.snappy(duration: 0.25)) { preview = next } }
                    }
                    .onEnded { _ in
                        withAnimation(.snappy) {
                            if let preview { save(preview) }
                            dragging = nil
                            preview = nil
                        }
                    }
            )
            .accessibilityLabel(QwertyLayout.name(id))
            .accessibilityHint("拖到底行或第三行右端调整位置")
    }

    private func save(_ l: QwertyLayout) {
        typing.qwerty = l
        typing.save()
    }
}

// MARK: - 顶栏按钮

struct ToolbarLayoutView: View {
    @Binding var typing: TypingPrefs

    var body: some View {
        List {
            Section {
                preview.listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            } footer: { Text("拖动右侧把手调整顺序。「状态」占满中间：排在它上面的按钮靠左，下面的靠右。改完下次弹出键盘生效。") }
            Section {
                ForEach(typing.toolbar, id: \.self) { id in
                    Label(Toolbar.name(id), systemImage: Self.icon(id))
                }
                .onMove { from, to in
                    typing.toolbar.move(fromOffsets: from, toOffset: to)
                    typing.save()
                }
            }
            Section {
                Button("恢复默认") {
                    typing.toolbar = Toolbar.all
                    typing.save()
                }
                .disabled(typing.toolbar == Toolbar.all)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("顶栏按钮")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var preview: some View {
        HStack(spacing: 6) {
            ForEach(typing.toolbar, id: \.self) { id in
                switch id {
                case "status": Text("状态").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                case "chip": capsule("渠道 ▾")
                case "layout": capsule("26 · 九键")
                default:
                    Image(systemName: Self.icon(id)).font(.footnote)
                        .foregroundStyle(id == "mic" ? Color.accentVK : .secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.systemBackground), in: Circle())
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 12))
        .animation(.snappy, value: typing.toolbar)
    }

    private func capsule(_ text: String) -> some View {
        Text(text).font(.caption).lineLimit(1).fixedSize()
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color(.systemBackground), in: Capsule())
    }

    private static func icon(_ id: String) -> String {
        switch id {
        case "mic": "mic.fill"
        case "chip": "antenna.radiowaves.left.and.right"
        case "status": "arrow.left.and.right"
        case "layout": "keyboard"
        case "recent": "clock.arrow.circlepath"
        default: "gearshape"
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
                    if typing.t9 {
                        NavigationLink("九宫格键位") { T9LayoutView(typing: $typing) }
                    }
                    NavigationLink("26 键键位") { QwertyLayoutView(typing: $typing) }
                    NavigationLink("顶栏按钮") { ToolbarLayoutView(typing: $typing) }
                    Toggle("按键震动", isOn: $typing.haptics)
                        .onChange(of: typing.haptics) { typing.save() }
                    Toggle("显示按键耗时", isOn: $typing.metrics)
                        .onChange(of: typing.metrics) { typing.save() }
                } header: { Text("键盘") } footer: { Text("键盘顶部「26 · 九键」随时切，切过就记住。九宫格和 26 键的功能键（删除、回车、123、中/英、空格等）可以拖动调整位置；顶栏按钮可以调整顺序。字母、数字键上滑输入角上的数字。按键震动需允许完全访问；按键耗时显示在键盘底部，排查卡顿用。") }
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
