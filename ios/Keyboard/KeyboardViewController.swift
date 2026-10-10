import Pinyin
import UIKit

/// 正式版键盘：打开默认打字（26 键全拼 / 九宫格），左上角麦克风进语音。界面按 design/ios/index.html，协议按 ios/PROTOCOL.md
final class KeyboardViewController: UIInputViewController {
    // MARK: 视图

    private let top = ToolBar()
    private let topArea = UIView()
    private let typeMic = MicButton(side: 32)
    private let typingButton = UIButton(type: .custom)
    private let layoutButton = UIButton(type: .system)
    /// layoutButton 当前标题对应的布局，避免每次按键重建富文本
    private var layoutTitleT9: Bool?
    private let compBar = CompBar()
    private let content = UIView()
    private let voiceBox = UIStackView()
    private let keypad = KeyPad()
    /// 语音模式底排的 🌐；系统已在键盘下方提供时隐藏
    private let voiceGlobe = KeyButton(symbol: "globe", style: .fn)
    /// 语音模式底排的换行键，标题同打字键盘随 returnKeyType 变
    private let voiceEnter = KeyButton("换行", style: .fn)
    private let grid = CandidateGrid()
    private var metricsLabel: UILabel?
    private let chip = UIButton(type: .system)
    private let chipDot = UIView()
    private let status = Theme.label(12, Theme.fg2)
    private let body = UIView()
    private let note = NoteView()

    private let idleBox = UIStackView()
    private let bigMic = MicButton(side: 76)
    private let bigLabel = Theme.label(13, weight: .medium)
    private let bigSub = Theme.label(11.5, Theme.fg2, lines: 2)

    private let singleBox = UIStackView()
    private let liveCard = UIView()
    private let liveText = Theme.label(15, lines: 3)
    private let liveActions = UIStackView()
    private let retryButton = UIButton(type: .system)
    private let wave = WaveView()
    private let smallMic = MicButton(side: 62)
    private let smallSpin = UIActivityIndicatorView(style: .medium)
    private let smallLabel = Theme.label(13, weight: .medium)

    private let panel = CandidatePanel()
    private let keyRow = UIStackView()
    private let actionKey = KeyButton(style: .actionRec)
    private let spaceKey = KeyButton("空格", style: .key)
    private var plainKeys: [UIView] = []
    /// 光标模式时淡化
    private var dimmed: [UIView] = []
    private var sheet: SheetView?
    private var toast: UILabel?
    private var clearTip: UILabel?
    /// 光标模式时顶栏的提示
    private let cursorTip = Theme.label(13, Theme.fg, weight: .medium)
    private var height: NSLayoutConstraint?
    /// 顶栏 + 内容；弹层透明，弹出时藏起
    private let column = UIStackView()
    /// 顶栏各位置的视图（Toolbar.all），按 prefs.toolbar 排列
    private var toolViews: [String: [UIView]] = [:]

    // MARK: 状态

    private enum Mode { case type, voice }
    private var mode = Mode.type
    private let composer = Composer()
    private var prefs = TypingPrefs()
    private var zh = true
    private var page = KeyPad.Page.abc
    private var shift = false
    /// 候选展开成网格
    private var expanded = false
    private var gridSig = ""
    private var compSig = (text: "", expanded: false)
    /// 本次按下空格 / 删除时正在组字
    private var spacePicks = false
    private var backComposing = false
    private var cursorKey: UIButton?
    private var cursorBlank = false
    private var dimmedNow: [UIView] = []

    private enum Purpose { case probe, start, watch }
    private struct Notice {
        var kind: NoteView.Kind
        var text: String
        var action: (title: String, run: () -> Void)?
    }

    private lazy var target = ProxyTarget(self)
    private var st: LiveState?
    /// 主 App 最近回应过（state 通知只会来自活着的主 App）
    private var alive = false
    private var lastHeard = 0.0
    private var ping: (at: Double, purpose: Purpose)?
    /// 已发出、尚未认领的 start
    private var mySeq = 0
    private var startAt = 0.0
    /// 用户点麦克风的时刻，随 start 带给主 App 统计开录延迟
    private var tapAt: Double?
    private var utt: Int?
    private var launch: String?
    private var multi = false
    private var typer: LiveTyper?
    private var typerNoted = false
    private var resyncing = false
    private var sel: String?
    private var pend: String?
    private var recSince: Double?
    private var lastPhase: LiveState.Phase?
    private var notice: Notice?
    private var ticker: Timer?
    private var repeatTimer: Timer?
    private var spaceHold: Timer?
    private var spaceX: CGFloat = 0
    /// 已写进输入框的拼音（marked text）
    private var marked = ""
    private var typingDocument: UUID?
    /// 本轮刚覆盖拼音上屏过：宿主会合并同一轮的写入并可能乱序，下一段拼音挪到下一轮再写
    private var committedThisTurn = false
    private var walk: CursorWalk?
    private var swipe: ClearSwipe?
    private var clearing: ClearPlan?
    /// 键盘正显示着（操作按钮的信号只给它）
    private var visible = false
    private let haptic = UISelectionFeedbackGenerator()
    /// 每次按键的轻震
    private let tapHaptic = UIImpactFeedbackGenerator(style: .light)
    /// 用户关掉的会话提醒：按会话结束时刻 / 到期时刻记
    private static var dismissedEnd: Double?
    private static var dismissedExpiry: Double?

    private var config: Config { Config.load() }
    private var now: Double { VK.now }

    /// 属于本键盘的那句话
    private var mine: LiveState.Utterance? {
        guard let utt, let s = st, s.launch == launch, let u = s.utterance, u.id == utt else { return nil }
        return u
    }

    private var sessionOn: Bool { alive && st?.session.active == true }
    /// 点麦克风可直接说（画中画待机被打断时为 false，须回主 App 重开）
    private var micOn: Bool { alive && st?.session.micReady == true }
    private var starting: Bool { (mySeq > 0 && utt == nil) || ping?.purpose == .start }
    private var busy: Bool { utt != nil || starting }

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        Bus.observe(VK.Note.state) { [weak self] in self?.received() }
        Bus.observe(VK.Note.hotkey) { [weak self] in self?.hotkey() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visible = true
        if hasFullAccess {
            Bus.write(KeyboardInfo(fullAccess: true, at: now), VK.File.keyboard)
            Bus.post(VK.Note.keyboard)
        }
        notice = nil
        prefs = TypingPrefs.load()
        applyToolbar()
        composer.layout = prefs.t9 ? .t9 : .qwerty
        composer.clear()
        marked = ""
        typingDocument = documentID
        PinyinLoader.warm(composer.layout)
        mode = .type
        page = .abc
        shift = false
        expanded = false
        showMetrics()
        st = LiveState.load()
        alive = st?.session.active == true
        sendPing(.probe)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        ticker?.invalidate()
        repeatTimer?.invalidate()
        ping = nil
        // 键盘收起：单渠道结束录音，定稿后由主 App 记入最近上屏；多渠道丢掉这句
        if let u = mine {
            if !multi, u.phase == .recording { CommandQueue.send(.stop, utt: u.id) }
            if multi { CommandQueue.send(.close, utt: u.id) }
        }
        typer?.abandon()
        reset()
        composer.clear()
        syncMarked()
        expanded = false
        closeSheet()
        endCursorMode()
        endBackTouch(clear: false)
        if let c = clearing { finishClear(c.text) }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let compact = traitCollection.verticalSizeClass == .compact
        // 与系统键盘同高：顶栏 44 + 四行键 210 + 上下留白
        height?.constant = compact ? 214 : 274
        bigSub.isHidden = compact
        voiceGlobe.isHidden = !needsInputModeSwitchKey
    }

    /// 尽量让系统别在键盘左右边缘等手势判定（按键区本身另用手势识别器绕开延迟）
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if reconcileTypingDocument() { render() } else { applyReturnKey() }
        if let typer, !typer.synced { resync() }
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        if reconcileTypingDocument() { render() }
    }

    /// 输入框身份。SDK 标成非可选 UUID，但系统偶尔给 nil（iOS 27 模拟器实测），直接读会在桥接时崩；走 ObjC 取值容忍 nil
    private var documentID: UUID? {
        let proxy = textDocumentProxy as AnyObject
        let getter = #selector(getter: UITextDocumentProxy.documentIdentifier)
        guard proxy.responds(to: getter) else { return nil }
        return proxy.perform(getter)?.takeUnretainedValue() as? UUID
    }

    @discardableResult
    private func reconcileTypingDocument() -> Bool {
        // 偶发的 nil 当作「未知」：不算换了输入框，也不覆盖已知的身份
        guard let id = documentID else { return false }
        defer { typingDocument = id }
        guard let typingDocument, typingDocument != id else { return false }
        // 焦点已换：只丢弃本地组字，不向新输入框清除旧 mark。
        composer.clear()
        marked = ""
        expanded = false
        return true
    }

    // MARK: 与主 App 通信

    private func received() {
        st = LiveState.load()
        alive = true
        lastHeard = now
        if let p = ping, let s = st, s.updatedAt >= p.at - 0.05 {
            ping = nil
            if p.purpose == .start {
                if s.session.micReady { startUtterance() } else { openApp() }
            }
        }
        follow()
        render()
    }

    private func sendPing(_ purpose: Purpose) {
        guard hasFullAccess else { return }
        let at = now
        ping = (at, purpose)
        Bus.post(VK.Note.ping)
        DispatchQueue.main.asyncAfter(deadline: .now() + (purpose == .watch ? 1 : 0.5)) { [weak self] in
            guard let self, let p = self.ping, p.at == at else { return }
            self.ping = nil
            self.alive = false
            switch purpose {
            case .start: self.openApp()
            case .watch: self.lost("VoiceKey 已断开，这句没有完成。点麦克风会重新开启会话。")
            case .probe: break
            }
            self.render()
        }
    }

    private func startUtterance() {
        reset()
        mySeq = CommandQueue.send(.start, silenceStop: config.silenceSeconds, tapAt: tapAt)
        startAt = now
    }

    private func tick() {
        if utt != nil, ping == nil, now - lastHeard > 2.5 { sendPing(.watch) }
        // 空闲时每 5 秒确认主 App 还活着；被杀后麦克风及时变空心
        if utt == nil, mySeq == 0, ping == nil, alive, now - lastHeard > 5 { sendPing(.probe) }
        if mySeq > 0, utt == nil, ping == nil, now - startAt > 3 {
            reset()
            show(.err, "VoiceKey 没有响应，请再点一次麦克风。")
        }
        if prefs.metrics { metricsLabel?.text = TypingStats.summary }
        render()
    }

    /// 认领自己发起的句子，并按状态推进（边说边打、候选上屏、失败处理）
    private func follow() {
        guard let s = st else { return }
        if utt == nil, mySeq > 0, let u = s.utterance, u.startSeq == mySeq {
            utt = u.id
            launch = s.launch
            multi = u.rows.count > 1
            typer = multi ? nil : LiveTyper(target)
            typerNoted = false
        }
        guard let id = utt else { return }
        guard s.launch == launch, let u = s.utterance, u.id == id else {
            return lost(s.launch != launch ? "VoiceKey 重新启动过，这句没有完成。" : nil)
        }
        if u.phase == .recording, lastPhase != .recording { recSince = now }
        lastPhase = u.phase
        if u.phase == .failed {
            let e = u.error
            reset()
            return startFailed(e)
        }
        multi ? followMulti(u) : followSingle(u)
    }

    private func followSingle(_ u: LiveState.Utterance) {
        guard let row = u.rows.first, let typer else { return }
        handle(typer.set(row.text))
        if u.phase == .done, row.state == .final, typer.synced || typer.halt != nil {
            CommandQueue.send(.close, utt: u.id)
            reset()
            mode = .type
        }
    }

    private func handle(_ o: LiveTyper.Outcome) {
        switch o {
        case .synced: break
        case .waiting:
            guard !resyncing else { return }
            resyncing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.resync() }
        case .halted:
            guard !typerNoted else { return }
            typerNoted = true
            Bus.log("keyboard typer halted: \(o)")
            show(.warn, "已停止边说边改，避免改动输入框里的其他文字。这句说完后可在「最近」里找到完整结果。", action: ("最近", { [weak self] in self?.showHistory() }))
        }
    }

    /// 用户移光标或清空：按现有规则停止边说边改，完整结果由主 App 记入最近
    private func stopLiveTyping() {
        guard let typer, typer.halt == nil else { return }
        typer.abandon()
        handle(.halted(.diverged))
    }

    private func resync() {
        resyncing = false
        follow()
        render()
    }

    private func followMulti(_ u: LiveState.Utterance) {
        sel = Dictation.selection(sel, lastPick: config.lastPick, rows: u.rows)
        guard let p = pend else { return }
        switch Dictation.settle(pending: p, in: u) {
        case .keep: break
        case .commit(let c): commit(c, in: u)
        case .failed(let fb):
            pend = nil
            sel = fb ?? sel
            show(.err, "你选的渠道没有结果，已改选其他渠道，请再点一次确认。")
        }
    }

    private func commit(_ ch: String, in u: LiveState.Utterance) {
        guard let r = u.rows.first(where: { $0.channel == ch }) else { return }
        textDocumentProxy.insertText(r.text)
        CommandQueue.send(.commit, utt: u.id, channel: ch)
        reset()
        mode = .type
        flash("已上屏 · \(r.name)")
    }

    private func startFailed(_ e: LiveState.StartError?) {
        switch e {
        case .noSession: openApp()
        case .micBusy: show(.err, "麦克风被占用：可能正在通话或其他 App 在录音，结束后再试。")
        case .noChannel: show(.err, "没有可用的识别渠道，请在 VoiceKey 里打开一个。", action: ("打开", { [weak self] in self?.openApp() }))
        case .bgDenied: openApp("后台没能开麦，正在打开 VoiceKey 改为常开麦…")
        case nil: show(.err, "没能开始，请再点一次麦克风。")
        }
    }

    private func lost(_ message: String?) {
        typer?.abandon()
        reset()
        if let message { show(.info, message) }
    }

    private func reset() {
        mySeq = 0
        utt = nil
        launch = nil
        typer = nil
        sel = nil
        pend = nil
        recSince = nil
        lastPhase = nil
    }

    // MARK: 操作

    private func tapMic() {
        guard hasFullAccess else {
            return show(.err, "未开启「允许完全访问」，键盘无法与 VoiceKey 通信。请到 设置 › VoiceKey › 键盘 打开。")
        }
        notice = nil
        let u = mine
        if u == nil, starting { return }
        switch Dictation.tap(u) {
        case .stop(let id): CommandQueue.send(.stop, utt: id)
        case .resume(let id):
            pend = nil
            CommandQueue.send(.continue, utt: id)
        case .begin:
            if u != nil { reset() }
            tapAt = now
            sendPing(.start)
        }
        render()
    }

    private func pick(_ ch: String) {
        guard let u = mine else { return }
        sel = ch
        switch Dictation.pick(ch, in: u) {
        case .commit(let c): commit(c, in: u)
        case .stopAndWait(let c):
            pend = c
            CommandQueue.send(.stop, utt: u.id)
            flash("定稿后上屏")
        case .wait(let c):
            pend = c
            flash("定稿后上屏")
        case .unavailable(let c):
            let name = u.rows.first { $0.channel == c }?.name ?? ""
            show(.err, "\(name) 没有结果，请选其他渠道或重试。")
        }
        render()
    }

    private func closeUtterance() {
        if let id = utt { CommandQueue.send(.close, utt: id) }
        typer?.abandon()
        reset()
        notice = nil
        render()
    }

    private func retry() {
        guard let u = mine else { return }
        notice = nil
        CommandQueue.send(.retry, utt: u.id)
    }

    /// 扩展没有 UIApplication.shared，沿响应链找到宿主的 UIApplication 调用 open
    private func openApp(_ message: String = "正在打开 VoiceKey 开启会话…") {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        var r: UIResponder? = self
        while let x = r {
            if NSStringFromClass(type(of: x)).hasSuffix("Application"), x.responds(to: sel) {
                typealias Open = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let f = unsafeBitCast(x.method(for: sel), to: Open.self)
                f(x, sel, VK.sessionURL as NSURL, NSDictionary(), { ok in Bus.log("open app ok=\(ok)") })
                show(.info, message)
                return
            }
            r = x.next
        }
        show(.err, "无法跳转，请手动打开 VoiceKey 开启会话。")
    }

    private func show(_ kind: NoteView.Kind, _ text: String, action: (String, () -> Void)? = nil) {
        notice = Notice(kind: kind, text: text, action: action.map { (title: $0.0, run: $0.1) })
        render()
    }

    private func flash(_ text: String) {
        toast?.removeFromSuperview()
        let l = Theme.label(13, .white)
        l.text = text
        l.backgroundColor = UIColor(red: 30 / 255, green: 30 / 255, blue: 40 / 255, alpha: 0.9)
        l.layer.cornerRadius = 14
        l.clipsToBounds = true
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            l.heightAnchor.constraint(equalToConstant: 28),
            l.widthAnchor.constraint(equalToConstant: l.intrinsicContentSize.width + 28),
        ])
        toast = l
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak l] in l?.removeFromSuperview() }
    }

    // MARK: 渠道 / 最近上屏

    private func showChannels() {
        guard hasFullAccess else { return show(.err, "需要「允许完全访问」才能切换渠道。") }
        let c = config
        let s = SheetView(title: "识别渠道")
        let toggle = UISwitch()
        toggle.isOn = c.isMulti
        toggle.isEnabled = c.enabled.count >= 2
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            if self.busy {
                toggle.setOn(!toggle.isOn, animated: true)
                return self.flash("说完这句再切换")
            }
            var c = self.config
            c.multi = toggle.isOn
            c.save()
            self.showChannels()
        }, for: .valueChanged)
        s.group([SheetView.cell("多渠道候选", sub: c.enabled.count < 2 ? "至少打开 2 个渠道（在 VoiceKey 里）" : "同时识别，选一条上屏", accessory: toggle)])
        if c.enabled.isEmpty {
            s.section("没有可用渠道，请在 VoiceKey 里打开")
        } else if c.isMulti {
            s.section("参与识别（在 VoiceKey 里增减）")
            s.group(c.enabled.map { SheetView.cell($0.name, accessory: SheetView.check(true)) })
        } else {
            s.section("单渠道时使用")
            s.group(c.enabled.map { ch in
                SheetView.cell(ch.name, accessory: SheetView.check(ch.id == c.active.first?.id)) { [weak self] in
                    guard let self else { return }
                    if self.busy { return self.flash("说完这句再切换") }
                    var c = self.config
                    c.defaultChannel = ch.id
                    c.save()
                    self.closeSheet()
                }
            })
        }
        present(s)
    }

    private func showHistory() {
        guard hasFullAccess else { return show(.err, "需要「允许完全访问」才能读取最近上屏。") }
        let items = Bus.read([HistoryItem].self, VK.File.history) ?? []
        let s = SheetView(title: "最近上屏")
        if items.isEmpty {
            s.group([SheetView.cell("还没有记录。没插进输入框的话，可以在这里找回。", lines: 0)])
        } else {
            s.section("点一条插入到光标处")
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            s.group(items.map { h in
                SheetView.cell(h.text, sub: "\(f.string(from: Date(timeIntervalSince1970: h.at))) · \(h.channel)", lines: 3) { [weak self] in
                    self?.textDocumentProxy.insertText(h.text)
                    self?.closeSheet()
                    self?.flash("已插入")
                }
            })
        }
        present(s)
    }

    private func present(_ s: SheetView) {
        closeSheet()
        s.onDone = { [weak self] in self?.closeSheet() }
        view.addSubview(s)
        column.alpha = 0
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            s.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            s.topAnchor.constraint(equalTo: view.topAnchor),
            s.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        sheet = s
    }

    private func closeSheet() {
        sheet?.removeFromSuperview()
        sheet = nil
        column.alpha = 1
        render()
    }

    // MARK: 渲染

    private func render() {
        guard isViewLoaded else { return }
        applyReturnKey()
        let full = hasFullAccess
        let u = mine
        let dm = Dictation.mode(u)
        let c = config
        let typing = mode == .type

        let name = c.isMulti ? "多渠道 · \(c.enabled.count)" : (c.active.first?.name ?? "无渠道")
        chip.setTitle("\(name) ▾", for: .normal)
        chipDot.backgroundColor = micOn ? Theme.ok : Theme.fg3
        status.text = typing ? (full ? (micOn ? "语音就绪" : "点麦克风说话") : "本地打字") : statusText(full, u, dm)
        typeMic.isHidden = !typing
        typeMic.look = full && micOn ? .solid : .outline
        typeMic.alpha = full ? 1 : 0.35
        typingButton.isHidden = typing
        voiceBox.isHidden = typing
        if typing { renderTyping() } else {
            keypad.isHidden = true
            grid.isHidden = true
            compBar.isHidden = true
            top.isHidden = false
            layoutButton.isHidden = true
        }

        let showPanel = multi && u != nil
        let showSingle = !multi && u != nil
        panel.isHidden = !showPanel
        singleBox.isHidden = !showSingle
        idleBox.isHidden = showPanel || showSingle
        if let u, showPanel { panel.update(u, selected: sel, pending: pend) }
        if let u, showSingle { renderSingle(u, dm) } else { wave.run(false) }
        if !idleBox.isHidden { renderIdle(full) }

        plainKeys.forEach { $0.isHidden = showPanel }
        actionKey.isHidden = !showPanel
        if let u, showPanel {
            if u.phase == .recording {
                actionKey.style = .actionRec
                actionKey.setImage(nil, for: .normal)
                actionKey.setTitle("■ 点按结束", for: .normal)
                actionKey.accessibilityLabel = "点按结束"
            } else {
                actionKey.style = .actionOutline
                actionKey.setImage(Theme.symbol("mic.fill", 13), for: .normal)
                actionKey.setTitle(u.phase == .finalizing ? " 接着说" : " 继续听", for: .normal)
                actionKey.accessibilityLabel = u.phase == .finalizing ? "接着说" : "继续听"
            }
        }

        // 打字时只提示会话快到期（短暂、可续期），其余会话提醒留在语音界面，避免长期盖住按键
        if let n = notice ?? sessionNotice(u).flatMap({ typing && $0.kind != .warn ? nil : $0 }) {
            note.isHidden = false
            note.show(n.kind, n.text, action: n.action?.title)
            note.onAction = { [weak self] in
                self?.notice = nil
                n.action?.run()
                self?.render()
            }
        } else {
            note.isHidden = true
        }
    }

    private func statusText(_ full: Bool, _ u: LiveState.Utterance?, _ mode: Dictation.Mode) -> String {
        if !full { return "未开完全访问" }
        if let u {
            switch mode {
            case .recording: return "聆听中 " + mmss(now - (recSince ?? now))
            case .finalizing, .idle: return "定稿中"
            case .picking: return u.rows.allSatisfy { $0.state == .error } ? "识别失败" : "选一条上屏"
            case .failed: return "识别失败"
            }
        }
        if starting { return "准备中" }
        if !sessionOn { return "未开启会话" }
        return st?.session.interrupted == true ? "麦克风被占用" : "会话中"
    }

    private func renderIdle(_ full: Bool) {
        bigMic.look = full && micOn ? .solid : .outline
        bigMic.alpha = full ? 1 : 0.35
        if !full {
            bigLabel.text = "需要完全访问"
            bigSub.text = "设置 › VoiceKey › 键盘 › 允许完全访问"
        } else if starting {
            bigLabel.text = "准备中…"
            bigSub.text = " "
        } else if micOn {
            bigLabel.text = "点按说话"
            bigSub.text = "再点一下结束 · 识别中再点＝接着说"
        } else if sessionOn {
            bigLabel.text = "点按回 VoiceKey"
            bigSub.text = "后台待命已停止，回 VoiceKey 重新开启"
        } else {
            bigLabel.text = "点按开启会话"
            bigSub.text = "会先跳到 VoiceKey 开启会话，再点左上角「◀」回来"
        }
    }

    private func renderSingle(_ u: LiveState.Utterance, _ mode: Dictation.Mode) {
        let row = u.rows.first
        let text = row?.text ?? ""
        let failed = mode == .failed
        liveActions.isHidden = !failed
        retryButton.isHidden = !u.retryable
        if failed {
            liveText.text = "识别失败：\(row?.error ?? "识别失败")。录音已保留。"
            liveText.textColor = Theme.err
            liveText.font = .systemFont(ofSize: 13.5)
        } else {
            liveText.text = text.isEmpty ? "请说话…" : text
            liveText.textColor = text.isEmpty || mode != .recording ? Theme.fg2 : Theme.fg
            liveText.font = .systemFont(ofSize: 15)
        }
        let recording = mode == .recording
        wave.isHidden = !recording || traitCollection.verticalSizeClass == .compact
        wave.level = u.level
        wave.run(recording)
        smallMic.look = recording ? .recording : .finalizing
        smallLabel.text = recording ? "点按结束" : failed ? "点按重新说" : "定稿中 · 点按接着说"
        smallSpin.isHidden = recording || failed
        if smallSpin.isHidden { smallSpin.stopAnimating() } else { smallSpin.startAnimating() }
    }

    /// 没有手动提示时，按会话状态给出提醒
    private func sessionNotice(_ u: LiveState.Utterance?) -> Notice? {
        guard hasFullAccess, u == nil, !starting, let s = st?.session else { return nil }
        if sessionOn, let e = s.idleExpiry, e > now, e - now < 30, e != Self.dismissedExpiry {
            return Notice(kind: .warn, text: "会话 \(mmss(e - now)) 后结束 · 现在说话会自动续期")
        }
        guard !s.active, let end = s.endedAt, now - end < 3600, end != Self.dismissedEnd else { return nil }
        switch s.endReason {
        case .idle:
            let m = s.idleMinutes
            return Notice(kind: .info, text: "会话已结束（\(m > 0 ? "\(m) 分钟" : "长时间")未使用）。点麦克风会重新开启。")
        case .interrupted: return Notice(kind: .info, text: "会话被通话或其他 App 打断后已结束。点麦克风会重新开启。")
        case .pipClosed: return Notice(kind: .info, text: "VoiceKey 后台待命已停止，会话已结束。点麦克风回 VoiceKey 重新开启。")
        case .bgDenied: return Notice(kind: .info, text: "后台没能开麦，会话已结束。点麦克风回 VoiceKey，本次改为常开麦。")
        case .micDenied: return Notice(kind: .err, text: "麦克风权限已关闭，点麦克风到 VoiceKey 里开启。")
        default: return nil
        }
    }

    private func mmss(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: 搭界面

    private func build() {
        let root: UIView = view
        // 顶栏：渠道芯片 · 状态 · 最近 · 打开 VoiceKey
        chip.setTitleColor(Theme.fg, for: .normal)
        chip.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        chip.titleLabel?.lineBreakMode = .byTruncatingTail
        ToolStyle.apply(chip, radius: 15)
        chip.contentEdgeInsets = UIEdgeInsets(top: 0, left: 23, bottom: 0, right: 11)
        chip.addAction(UIAction { [weak self] _ in self?.showChannels() }, for: .touchUpInside)
        chipDot.layer.cornerRadius = 3.5
        chipDot.isUserInteractionEnabled = false
        chipDot.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipDot)
        status.textAlignment = .center
        status.lineBreakMode = .byTruncatingTail
        let recent = iconButton("clock.arrow.circlepath", "最近上屏") { [weak self] in self?.showHistory() }
        let gear = iconButton("gearshape", "打开 VoiceKey") { [weak self] in self?.openApp() }
        // 打字时左上角麦克风进语音；语音时换成「返回打字」
        typeMic.accessibilityLabel = "语音输入"
        typeMic.addAction(UIAction { [weak self] _ in self?.tapTypeMic() }, for: .touchUpInside)
        typingButton.setImage(Theme.symbol("keyboard", 16, .medium), for: .normal)
        typingButton.tintColor = Theme.fg2
        ToolStyle.apply(typingButton, radius: 16)
        typingButton.accessibilityLabel = "返回打字"
        typingButton.addAction(UIAction { [weak self] _ in self?.backToTyping() }, for: .touchUpInside)
        // 26 键 / 九键：一个胶囊，点一下切换（原分段控件太小，常按不中）
        ToolStyle.apply(layoutButton, radius: 15)
        layoutButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 11, bottom: 0, right: 11)
        layoutButton.accessibilityLabel = "中文键盘布局"
        layoutButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setLayout(t9: !self.prefs.t9)
        }, for: .touchUpInside)
        toolViews = ["mic": [typeMic, typingButton], "chip": [chip], "status": [status], "layout": [layoutButton], "recent": [recent], "gear": [gear]]
        applyToolbar()
        top.spacing = 7
        top.alignment = .center
        top.isLayoutMarginsRelativeArrangement = true
        top.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0)
        layoutButton.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 待命：大麦克风
        bigMic.addAction(UIAction { [weak self] _ in self?.tapMic() }, for: .touchUpInside)
        bigSub.textAlignment = .center
        idleBox.addArrangedSubviews([bigMic, bigLabel, bigSub])
        idleBox.axis = .vertical
        idleBox.alignment = .center
        idleBox.setCustomSpacing(9, after: bigMic)
        idleBox.setCustomSpacing(2, after: bigLabel)

        // 单渠道：实时文字 + 声波 + 小麦克风
        liveCard.backgroundColor = Theme.key
        liveCard.layer.cornerRadius = 10
        liveText.lineBreakMode = .byTruncatingHead
        retryButton.setTitle("重试", for: .normal)
        retryButton.tintColor = Theme.accent
        retryButton.addAction(UIAction { [weak self] _ in self?.retry() }, for: .touchUpInside)
        let discard = UIButton(type: .system)
        discard.setTitle("丢弃", for: .normal)
        discard.tintColor = Theme.fg2
        discard.addAction(UIAction { [weak self] _ in self?.closeUtterance() }, for: .touchUpInside)
        liveActions.addArrangedSubviews([retryButton, discard, UIView()])
        liveActions.spacing = 14
        let liveCol = UIStackView(arrangedSubviews: [liveText, liveActions])
        liveCol.axis = .vertical
        liveCol.spacing = 2
        liveCol.translatesAutoresizingMaskIntoConstraints = false
        liveCard.addSubview(liveCol)
        NSLayoutConstraint.activate([
            liveCol.leadingAnchor.constraint(equalTo: liveCard.leadingAnchor, constant: 11),
            liveCol.trailingAnchor.constraint(equalTo: liveCard.trailingAnchor, constant: -11),
            liveCol.topAnchor.constraint(equalTo: liveCard.topAnchor, constant: 8),
            liveCol.bottomAnchor.constraint(equalTo: liveCard.bottomAnchor, constant: -8),
            liveCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        smallMic.addAction(UIAction { [weak self] _ in self?.tapMic() }, for: .touchUpInside)
        smallSpin.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        let labelRow = UIStackView(arrangedSubviews: [smallSpin, smallLabel])
        labelRow.spacing = 2
        singleBox.addArrangedSubviews([liveCard, wave, smallMic, labelRow])
        singleBox.axis = .vertical
        singleBox.alignment = .center
        singleBox.spacing = 8
        singleBox.setCustomSpacing(6, after: smallMic)

        // 多渠道：候选框
        panel.onPick = { [weak self] in self?.pick($0) }
        panel.onClose = { [weak self] in self?.closeUtterance() }
        panel.onRetry = { [weak self] in self?.retry() }

        note.isHidden = true
        note.onClose = { [weak self] in
            guard let self else { return }
            if self.notice == nil, let s = self.st?.session {
                if s.active { Self.dismissedExpiry = s.idleExpiry } else { Self.dismissedEnd = s.endedAt }
            }
            self.notice = nil
            self.render()
        }

        for v in [idleBox, singleBox, panel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(v)
        }
        NSLayoutConstraint.activate([
            idleBox.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            idleBox.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            idleBox.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -20),
            bigSub.widthAnchor.constraint(lessThanOrEqualToConstant: 290),
            singleBox.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            singleBox.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 10),
            singleBox.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -10),
            liveCard.widthAnchor.constraint(equalTo: singleBox.widthAnchor),
            panel.topAnchor.constraint(equalTo: body.topAnchor, constant: 2),
            panel.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -6),
            panel.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 6),
            panel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -6),
        ])

        // 底排：🌐 ， 空格 。 ⌫ 换行；候选框时 🌐 [大键] ⌫
        let globe = voiceGlobe
        globe.accessibilityLabel = "切换输入法"
        globe.addTarget(self, action: #selector(globeEvent(_:event:)), for: .allTouchEvents)
        let comma = textKey("，", "，", style: .fn)
        spaceKey.addTarget(self, action: #selector(spaceTouch(_:event:)), for: [.touchDown, .touchDragInside, .touchDragOutside, .touchUpInside, .touchUpOutside, .touchCancel])
        let period = textKey("。", "。", style: .fn)
        let back = KeyButton(symbol: "delete.left", style: .fn)
        back.accessibilityLabel = "删除"
        back.addTarget(self, action: #selector(backTouch(_:event:)), for: [.touchDown, .touchDragInside, .touchDragOutside, .touchUpInside, .touchUpOutside, .touchCancel])
        let enter = voiceEnter
        enter.fontSize = 15
        enter.titleLabel?.adjustsFontSizeToFitWidth = true
        enter.addAction(UIAction { [weak self] _ in
            guard let self, self.returnKey.enabled else { return }
            self.textDocumentProxy.insertText("\n")
        }, for: .touchUpInside)
        actionKey.addAction(UIAction { [weak self] _ in self?.tapMic() }, for: .touchUpInside)
        plainKeys = [comma, spaceKey, period, enter]
        dimmed = [top, body, globe, comma, period, back, enter]
        cursorTip.text = "‹  左右滑动移动光标 · 松手结束  ›"
        cursorTip.textAlignment = .center
        cursorTip.isHidden = true
        cursorTip.translatesAutoresizingMaskIntoConstraints = false
        topArea.addSubview(cursorTip)
        NSLayoutConstraint.activate([
            cursorTip.centerXAnchor.constraint(equalTo: topArea.centerXAnchor),
            cursorTip.centerYAnchor.constraint(equalTo: topArea.centerYAnchor),
            cursorTip.widthAnchor.constraint(lessThanOrEqualTo: topArea.widthAnchor, constant: -16),
        ])
        keyRow.addArrangedSubviews([globe, comma, spaceKey, period, actionKey, back, enter])
        keyRow.spacing = 6
        for k in [globe, comma, period, back, enter] { k.widthAnchor.constraint(equalToConstant: 46).isActive = true }

        voiceBox.addArrangedSubviews([body, keyRow])
        voiceBox.axis = .vertical

        // 打字：按键区 / 展开的候选；组字时候选栏盖住顶栏
        keypad.wire = { [weak self] b, key in self?.wire(b, key) }
        keypad.onTrack = { [weak self] b, key, phase, touch in
            switch key {
            case .space: self?.spaceTrack(b, phase, touch)
            case .back: self?.backTrack(b, phase, touch)
            default: break
            }
        }
        keypad.onCursor = { [weak self] b, phase, touch in self?.cursorTrack(b, phase, touch) }
        keypad.canCursor = { [weak self] in
            guard let self else { return false }
            return self.mode == .type && !self.composer.isComposing && self.cursorKey == nil
        }
        keypad.onFeedback = { [weak self] in self?.keyFeedback() }
        keypad.onKey = { [weak self] in self?.press($0) }
        keypad.onList = { [weak self] item, pinyin in
            guard let self else { return }
            if pinyin { self.timed { self.composer.pickPinyin(item) } } else { self.commitThen(item) }
        }
        compBar.onPick = { [weak self] i in self?.pickCandidate(i) }
        compBar.onMore = { [weak self] in self?.timed { self?.expanded.toggle() } }
        grid.source = { [weak self] in self?.composer.candidates(from: $0, limit: $1) ?? [] }
        grid.onPick = { [weak self] i in self?.pickCandidate(i) }
        grid.onCollapse = { [weak self] in self?.timed { self?.expanded = false } }
        grid.onRetype = { [weak self] in self?.timed { self?.composer.clear() } }
        wire(grid.back, .back)

        for (v, parent) in [(top, topArea), (compBar, topArea), (voiceBox, content), (keypad, content), (grid, content)] as [(UIView, UIView)] {
            v.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: parent.leadingAnchor), v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                v.topAnchor.constraint(equalTo: parent.topAnchor), v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            ])
        }
        note.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(note)
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
        ])

        column.addArrangedSubviews([topArea, content])
        column.axis = .vertical
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        let h = root.heightAnchor.constraint(equalToConstant: 274)
        h.priority = .init(999)
        height = h
        NSLayoutConstraint.activate([
            h,
            chipDot.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            chipDot.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chipDot.widthAnchor.constraint(equalToConstant: 7), chipDot.heightAnchor.constraint(equalToConstant: 7),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            chip.heightAnchor.constraint(equalToConstant: 30),
            layoutButton.heightAnchor.constraint(equalToConstant: 30),
            topArea.heightAnchor.constraint(equalToConstant: 44),
            typingButton.widthAnchor.constraint(equalToConstant: 32), typingButton.heightAnchor.constraint(equalToConstant: 32),
            keyRow.heightAnchor.constraint(equalToConstant: 42),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
        ])
    }

    private func applyToolbar() {
        let order = prefs.toolbar.flatMap { toolViews[$0] ?? [] }
        guard top.arrangedSubviews != order else { return }
        top.arrangedSubviews.forEach { top.removeArrangedSubview($0) }
        top.addArrangedSubviews(order)
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(Theme.symbol(symbol, 16, .medium), for: .normal)
        b.tintColor = Theme.fg2
        ToolStyle.apply(b, radius: 17)
        b.accessibilityLabel = label
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 34).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    // MARK: 打字

    private func tapTypeMic() {
        guard hasFullAccess else {
            return show(.err, "打字可正常使用。语音需要「允许完全访问」：设置 › VoiceKey › 键盘。")
        }
        mode = .voice
        expanded = false
        composer.clear()
        syncMarked()
        tapMic()
    }

    /// 操作按钮 / 快捷指令：只有正在显示的键盘响应；同点麦克风（开始、说话中则结束）
    private func hotkey() {
        guard visible, hasFullAccess, let request = Bus.read(HotkeyRequest.self, VK.File.hotkey),
              request.accepts(now: now, visible: visible, fullAccess: hasFullAccess,
                              acknowledged: Bus.read(String.self, VK.File.hotkeyAck)) else { return }
        Bus.write(request.id, VK.File.hotkeyAck)
        Bus.post(VK.Note.hotkeyAck)
        closeSheet()
        tapTypeMic()
    }

    private func backToTyping() {
        if busy { return flash("先结束或关闭这一句") }
        notice = nil
        mode = .type
        render()
    }

    /// 键盘里切布局：同步改默认布局，下次打开沿用
    private func setLayout(t9: Bool) {
        timed {
            composer.clear()
            expanded = false
            page = .abc
            prefs.t9 = t9
            if TypingPrefs.toggleSetsDefault { prefs.save() }
            composer.layout = t9 ? .t9 : .qwerty
        }
        PinyinLoader.warm(composer.layout)
        flash(t9 ? "已切到九宫格 · 下次打开沿用" : "已切到 26 键 · 下次打开沿用")
    }

    private func renderTyping() {
        let composing = zh && composer.isComposing
        if !composing { expanded = false }
        keypad.set(KeyPad.Spec(t9: zh && prefs.t9, zh: zh, page: page, shift: shift && !zh, globe: needsInputModeSwitchKey, t9Layout: prefs.t9Layout, qwertyLayout: prefs.qwerty))
        if cursorKey == nil { keypad.update(composing: composing, pinyin: zh ? composer.pinyinOptions : []) }
        keypad.isHidden = expanded
        grid.isHidden = !expanded
        top.isHidden = composing
        compBar.isHidden = !composing
        layoutButton.isHidden = !zh
        if layoutTitleT9 != prefs.t9 {
            layoutTitleT9 = prefs.t9
            let on = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.fg]
            let off = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 13), .foregroundColor: Theme.fg3]
            let title = NSMutableAttributedString(string: "26", attributes: prefs.t9 ? off : on)
            title.append(NSAttributedString(string: " · ", attributes: off))
            title.append(NSAttributedString(string: "九键", attributes: prefs.t9 ? on : off))
            layoutButton.setAttributedTitle(title, for: .normal)
            layoutButton.accessibilityValue = prefs.t9 ? "九宫格" : "26 键"
        }
        guard composing else { return gridSig = "" }
        let p = composer.preedit, cands = composer.candidates
        let sig = p.confirmed + "|" + p.picked.joined(separator: "'") + "|" + p.guess.joined(separator: "'") + "|" + cands.joined(separator: " ")
        if sig != compSig.text || expanded != compSig.expanded {
            compSig = (sig, expanded)
            compBar.update(confirmed: p.confirmed, picked: p.picked, guess: p.guess, candidates: cands, expanded: expanded)
        }
        if expanded, gridSig != sig {
            gridSig = sig
            grid.reload()
        }
    }

    /// 🌐、展开候选里的 ⌫ 等真按钮接原有的触摸处理
    private func wire(_ b: KeyButton, _ key: KeyPad.Key) {
        let touches: UIControl.Event = [.touchDown, .touchDragInside, .touchDragOutside, .touchUpInside, .touchUpOutside, .touchCancel]
        switch key {
        case .space: b.addTarget(self, action: #selector(spaceTouch(_:event:)), for: touches)
        case .back: b.addTarget(self, action: #selector(backTouch(_:event:)), for: touches)
        case .globe: b.addTarget(self, action: #selector(globeEvent(_:event:)), for: .allTouchEvents)
        default: break
        }
    }

    private func press(_ key: KeyPad.Key) {
        reconcileTypingDocument()
        switch key {
        case .letter(let c):
            guard !zh else { return timed { insert(composer.type(c)) } }
            insert(shift ? c.uppercased() : String(c))
            if shift {
                shift = false
                render()
            }
        case .digit(let c): timed { insert(composer.type(c)) }
        case .one: timed { composer.one() }
        case .text(let s): commitThen(s)
        case .enter:
            if zh, composer.isComposing { timed { insert(composer.commitRaw()) } } else if returnKey.enabled { insert("\n") }
        case .newline: commitThen("\n")
        case .shift:
            shift.toggle()
            render()
        case .lang:
            if composer.isComposing { insert(composer.commitRaw()) }
            zh.toggle()
            shift = false
            expanded = false
            render()
        case .page(let p):
            page = p
            render()
        // 空格、删除平时走 onTrack，这里只有旁白激活会进来
        case .space:
            if mode == .type, zh, composer.isComposing { pickCandidate(0) } else { insert(" ") }
        case .back: deleteOne()
        case .globe: break
        }
    }

    /// 按下即反馈：按键音跟随系统「键盘点击声」，震动需完全访问且设置里开着
    private func keyFeedback() {
        UIDevice.current.playInputClick()
        guard prefs.haptics, hasFullAccess else { return }
        tapHaptic.impactOccurred(intensity: 0.7)
        tapHaptic.prepare()
    }

    /// 标点、数字：组字中先按首选上屏
    private func commitThen(_ s: String) {
        timed { insert(composer.confirmAll() + s) }
    }

    private func insert(_ s: String) {
        defer { applyReturnKey() }
        guard !reconcileTypingDocument() else { return }
        guard !s.isEmpty else { return }
        guard !marked.isEmpty else { return textDocumentProxy.insertText(s) }
        // 覆盖输入框里的拼音上屏：Apple 文档的做法，改成最终文字再 unmark，同一次写完（标点也并进来）
        textDocumentProxy.setMarkedText(s, selectedRange: NSRange(location: (s as NSString).length, length: 0))
        textDocumentProxy.unmarkText()
        marked = ""
        committedThisTurn = true
        DispatchQueue.main.async { [weak self] in self?.committedThisTurn = false }
    }

    /// 组字变化后把拼音同步到输入框；不再组字时清掉
    private func syncMarked() {
        guard !reconcileTypingDocument() else { return }
        var want = ""
        if prefs.inlinePinyin, mode == .type, zh, composer.isComposing {
            let p = composer.preedit
            want = p.confirmed + (p.picked + p.guess).joined(separator: "'")
        }
        guard want != marked else { return }
        if committedThisTurn, !want.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.syncMarked() }
            return
        }
        let p = textDocumentProxy
        if want.isEmpty {
            p.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
            p.unmarkText()
        } else {
            p.setMarkedText(want, selectedRange: NSRange(location: (want as NSString).length, length: 0))
        }
        marked = want
    }

    private func pickCandidate(_ i: Int) {
        timed {
            if let t = composer.select(i) { insert(t) }
        }
    }

    /// 组字类按键：计时（引擎 / 刷新界面并布局），测试时显示到键盘上
    private func timed(_ body: () -> Void) {
        reconcileTypingDocument()
        TypingStats.begin()
        body()
        syncMarked()
        TypingStats.engineDone()
        render()
        view.layoutIfNeeded()
        TypingStats.end()
        if prefs.metrics { metricsLabel?.text = TypingStats.summary }
    }

    private func showMetrics() {
        guard prefs.metrics else {
            metricsLabel?.removeFromSuperview()
            metricsLabel = nil
            return
        }
        if metricsLabel == nil {
            let l = Theme.label(8, Theme.fg3)
            l.accessibilityIdentifier = "metrics"
            l.isUserInteractionEnabled = false
            l.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                l.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                l.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            metricsLabel = l
        }
        metricsLabel?.text = TypingStats.summary
    }

    private func textKey(_ title: String, _ text: String, style: KeyButton.Style) -> KeyButton {
        let k = KeyButton(title, style: style)
        k.addAction(UIAction { [weak self] _ in
            self?.textDocumentProxy.insertText(text)
            self?.applyReturnKey()
        }, for: .touchUpInside)
        return k
    }

    /// 输入框声明的回车动作（搜索、发送……）；enablesReturnKeyAutomatically 时空输入框置灰
    private var returnKey: KeyPad.ReturnKey {
        let p = textDocumentProxy
        let enabled = p.enablesReturnKeyAutomatically != true || p.hasText
        return KeyPad.ReturnKey(type: p.returnKeyType ?? .default, enabled: enabled)
    }

    private func applyReturnKey() {
        let r = returnKey
        keypad.returnKey = r
        guard voiceEnter.title(for: .normal) != r.title || voiceEnter.muted == r.enabled else { return }
        voiceEnter.setTitle(r.title, for: .normal)
        voiceEnter.accessibilityLabel = r.title
        voiceEnter.style = r.accent ? .enter : .fn
        voiceEnter.muted = !r.enabled
    }

    private func startRepeat() {
        deleteOne()
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                self?.deleteOne()
            }
        }
    }

    /// 组字中删一个按键，否则删输入框的字
    private func deleteOne() {
        if mode == .type, composer.isComposing {
            timed { _ = composer.deleteBackward() }
        } else {
            textDocumentProxy.deleteBackward()
            applyReturnKey()
        }
    }

    // MARK: 长按移光标（空格按住即进入，其他键按住后拖动进入）

    /// 短按输入空格（组字中选首选词）；按住 0.3 秒进光标模式，松手退出、不插空格
    @objc private func spaceTouch(_ sender: UIButton, event: UIEvent) {
        guard let t = event.touches(for: sender)?.first else { return }
        spaceTrack(sender, t.phase, t)
    }

    private func spaceTrack(_ sender: UIButton, _ phase: UITouch.Phase, _ t: UITouch) {
        spaceX = t.location(in: view).x
        switch phase {
        case .began:
            spaceHold?.invalidate()
            spacePicks = mode == .type && composer.isComposing
            guard !spacePicks else { return }
            spaceHold = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self, weak sender] _ in
                guard let self, let sender else { return }
                self.beginCursorMode(sender, x: self.spaceX, blank: true)
            }
        case .moved: moveCursor(to: spaceX)
        case .ended:
            // 键缝也算这个键，松手判定放宽到半个键距外
            let inside = sender.bounds.insetBy(dx: -8, dy: -8).contains(t.location(in: sender))
            if spacePicks {
                spacePicks = false
                if inside { pickCandidate(0) }
                return
            }
            moveCursor(to: spaceX)
            let tap = walk == nil && spaceHold?.isValid == true && inside
            endCursorMode()
            if tap { textDocumentProxy.insertText(" ") }
        default:
            spacePicks = false
            endCursorMode()
        }
    }

    /// 其他键按住后拖动：进入即移光标，松手只退出
    private func cursorTrack(_ sender: UIButton, _ phase: UITouch.Phase, _ t: UITouch) {
        let x = t.location(in: view).x
        switch phase {
        case .began: beginCursorMode(sender, x: x, blank: false)
        case .moved: moveCursor(to: x)
        default: endCursorMode()
        }
    }

    /// blank：按键文字让位（空格键整条当触控板）
    private func beginCursorMode(_ sender: UIButton, x: CGFloat, blank: Bool) {
        walk = CursorWalk(before: textDocumentProxy.documentContextBeforeInput, after: textDocumentProxy.documentContextAfterInput, x: x)
        haptic.prepare()
        if blank { sender.setTitle(nil, for: .normal) }
        cursorBlank = blank
        cursorKey = sender
        dimmedNow = mode == .type ? [top, keypad.sideList] + keypad.keys.filter { $0 !== sender } : dimmed
        dimmedNow.forEach { $0.alpha = 0.35 }
        // 顶栏让位给提示，结束时随 dimmedNow 一起恢复
        top.alpha = 0
        topArea.bringSubviewToFront(cursorTip)
        cursorTip.isHidden = false
    }

    private func moveCursor(to x: CGFloat) {
        guard var w = walk else { return }
        let n = w.steps(to: x), dir = n < 0 ? -1 : 1
        for _ in 0 ..< abs(n) {
            var off = w.step(dir)
            if off == nil {
                // 快照到头：宿主上下文窗口有限，换最新的再走
                w.refill(before: textDocumentProxy.documentContextBeforeInput, after: textDocumentProxy.documentContextAfterInput)
                off = w.step(dir)
            }
            guard let off else { break }
            stopLiveTyping()
            textDocumentProxy.adjustTextPosition(byCharacterOffset: off)
            haptic.selectionChanged()
            haptic.prepare()
        }
        walk = w
    }

    private func endCursorMode() {
        spaceHold?.invalidate()
        walk = nil
        guard let key = cursorKey else { return }
        cursorKey = nil
        if cursorBlank { key.setTitle("空格", for: .normal) }
        dimmedNow.forEach { $0.alpha = 1 }
        dimmedNow = []
        cursorTip.isHidden = true
        if mode == .type { keypad.update(composing: zh && composer.isComposing, pinyin: zh ? composer.pinyinOptions : []) }
    }

    // MARK: 删除键：按住连删，上滑清空（组字中清拼音）

    @objc private func backTouch(_ sender: UIButton, event: UIEvent) {
        guard let t = event.touches(for: sender)?.first else { return }
        backTrack(sender, t.phase, t)
    }

    private func backTrack(_ sender: UIButton, _ phase: UITouch.Phase, _ t: UITouch) {
        let y = t.location(in: view).y
        switch phase {
        case .began:
            backComposing = mode == .type && composer.isComposing
            startRepeat()
            // 清掉的文字要存进「最近」，没有完全访问写不了，不提供清空；清拼音不受限
            guard backComposing || hasFullAccess, clearing == nil else { return }
            swipe = ClearSwipe(y: y)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak sender] in
                guard let self, let sender, self.swipe != nil else { return }
                self.showClearTip(above: sender)
            }
        case .moved:
            guard var s = swipe else { return }
            s.move(to: y)
            swipe = s
            if s.swiped { repeatTimer?.invalidate() }
            if s.armed || s.swiped { showClearTip(above: sender) }
        case .ended:
            swipe?.move(to: y)
            endBackTouch(clear: swipe?.armed == true)
        default: endBackTouch(clear: false)
        }
    }

    private func endBackTouch(clear: Bool) {
        repeatTimer?.invalidate()
        swipe = nil
        clearTip?.removeFromSuperview()
        clearTip = nil
        if clear, backComposing {
            timed { composer.clear() }
            flash("已清除拼音")
        } else if clear {
            clearField()
        }
        backComposing = false
    }

    private func showClearTip(above key: UIView) {
        let armed = swipe?.armed == true
        let l = clearTip ?? Theme.label(13, .white)
        l.text = armed ? (backComposing ? "松手清拼音" : "松手清空") : "上滑清空"
        l.backgroundColor = armed ? Theme.err : UIColor(red: 30 / 255, green: 30 / 255, blue: 40 / 255, alpha: 0.9)
        l.textAlignment = .center
        l.layer.cornerRadius = 8
        l.clipsToBounds = true
        if clearTip == nil { view.addSubview(l) }
        clearTip = l
        let k = key.convert(key.bounds, to: view)
        let w: CGFloat = 84, h: CGFloat = 30
        l.frame = CGRect(x: min(max(4, k.midX - w / 2), view.bounds.width - w - 4), y: k.minY - h - 8, width: w, height: h)
    }

    /// 先把光标移到末尾再往前删；宿主执行慢一拍，每步等上下文跟上
    private func clearField() {
        guard clearing == nil else { return }
        stopLiveTyping()
        clearing = ClearPlan()
        clearRound()
    }

    private func clearRound() {
        guard var plan = clearing else { return }
        let p = textDocumentProxy
        let op = plan.next(before: p.documentContextBeforeInput, after: p.documentContextAfterInput)
        clearing = plan
        switch op {
        case .toEnd(let n): p.adjustTextPosition(byCharacterOffset: n)
        case .delete(let n): for _ in 0 ..< n { p.deleteBackward() }
        case .wait: break
        case .done: return finishClear(plan.text)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.clearRound() }
    }

    private func finishClear(_ text: String) {
        clearing = nil
        guard !text.isEmpty else { return }
        var items = Bus.read([HistoryItem].self, VK.File.history) ?? []
        items.insert(HistoryItem(text: text, channel: "已清空", at: now), at: 0)
        Bus.write(Array(items.prefix(20)), VK.File.history)
        if isViewLoaded, view.window != nil { flash("已清空 · 可在「最近」找回") }
    }

    /// 🌐：一句话进行中先提示结束，否则交给系统（点按切换、长按列表）
    @objc private func globeEvent(_ sender: UIButton, event: UIEvent) {
        if busy {
            if event.allTouches?.first?.phase == .ended { flash("先结束或关闭这一句") }
            return
        }
        handleInputModeList(from: sender, with: event)
    }
}

/// textDocumentProxy 适配 LiveTyper
private final class ProxyTarget: TextTarget {
    private weak var vc: UIInputViewController?
    init(_ vc: UIInputViewController) { self.vc = vc }
    private var proxy: UITextDocumentProxy? { vc?.textDocumentProxy }
    var before: String? { proxy?.documentContextBeforeInput }
    /// 光标在末尾时不同宿主给 nil 或 ""，统一成 ""
    var after: String? { proxy?.documentContextAfterInput ?? "" }
    var selected: String? { proxy?.selectedText }
    func insert(_ text: String) { proxy?.insertText(text) }
    func deleteBackward() { proxy?.deleteBackward() }
}

private extension UIStackView {
    func addArrangedSubviews(_ views: [UIView]) { views.forEach(addArrangedSubview) }
}

/// 键盘视图声明支持按键音，UIDevice.playInputClick 才会按系统「键盘点击声」设置出声
extension UIInputView: @retroactive UIInputViewAudioFeedback {
    public var enableInputClicksWhenVisible: Bool { true }
}
