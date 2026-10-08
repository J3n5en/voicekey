import UIKit

/// 配色取自设计稿 design/ios/index.html
enum Theme {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
    }
    static func dyn(_ light: UIColor, _ dark: UIColor) -> UIColor { UIColor { $0.userInterfaceStyle == .dark ? dark : light } }

    static let kb = dyn(hex(0xd3d6dd), hex(0x2c2c30))
    static let key = dyn(hex(0xffffff), hex(0x6b6b70))
    static let key2 = dyn(hex(0xadb2bc), hex(0x46464b))
    static let fg = dyn(hex(0x111111), hex(0xffffff))
    static let fg2 = dyn(hex(0x5c5f6e), hex(0xb0b2c0))
    static let fg3 = dyn(hex(0x9a9cab), hex(0x8a8c9a))
    static let line = dyn(hex(0x141428, 0.1), hex(0xffffff, 0.12))
    static let accent = dyn(hex(0x6a5cff), hex(0x9d94ff))
    static let rec = hex(0xff3b30)
    static let ok = hex(0x1fb57a)
    static let warn = hex(0xf0a020)
    static let err = hex(0xef4a5a)
    static let gradient = [hex(0x22c3ff), hex(0x7b5cff), hex(0xff3d8b)].map(\.cgColor)

    static func gradientLayer() -> CAGradientLayer {
        let g = CAGradientLayer()
        g.colors = gradient
        g.locations = [0, 0.55, 1]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        return g
    }

    static func label(_ size: CGFloat, _ color: UIColor = fg, weight: UIFont.Weight = .regular, lines: Int = 1) -> UILabel {
        let l = UILabel()
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.numberOfLines = lines
        return l
    }

    static func symbol(_ name: String, _ size: CGFloat, _ weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }
}

/// 动态颜色转 CGColor 要在 layoutSubviews 里按当前外观解析
class ThemedView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: ThemedView, _) in v.setNeedsLayout() }
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 麦克风

final class MicButton: UIControl {
    enum Look { case solid, outline, recording, finalizing }

    var look = Look.solid { didSet { if look != oldValue { refresh() } } }
    private let side: CGFloat
    private let grad = Theme.gradientLayer()
    private let pulse = CALayer()
    private let icon = UIImageView()
    private let stopMark = UIView()

    init(side: CGFloat) {
        self.side = side
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = side / 2
        pulse.cornerRadius = side / 2
        grad.cornerRadius = side / 2
        layer.addSublayer(pulse)
        layer.addSublayer(grad)
        icon.contentMode = .center
        stopMark.layer.cornerRadius = side * 0.05
        stopMark.backgroundColor = .white
        for v in [icon, stopMark] {
            v.isUserInteractionEnabled = false
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            v.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
            v.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side), heightAnchor.constraint(equalToConstant: side),
            stopMark.widthAnchor.constraint(equalToConstant: side * 0.24), stopMark.heightAnchor.constraint(equalToConstant: side * 0.24),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "麦克风"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: MicButton, _) in v.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { transform = isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        grad.frame = bounds
        pulse.frame = bounds
    }

    private func refresh() {
        let t = traitCollection
        let accent = Theme.accent.resolvedColor(with: t)
        grad.isHidden = look != .solid
        stopMark.isHidden = look != .recording
        icon.isHidden = look == .recording
        icon.image = Theme.symbol(look == .outline ? "mic" : "mic.fill", side * 0.36, .medium)
        icon.tintColor = look == .solid ? .white : accent
        backgroundColor = look == .recording ? Theme.rec : Theme.key
        layer.borderWidth = look == .outline || look == .finalizing ? 2 : 0
        layer.borderColor = accent.cgColor
        layer.shadowColor = Theme.hex(0x6a5cff).cgColor
        layer.shadowOpacity = look == .solid ? 0.35 : 0
        layer.shadowRadius = 9
        layer.shadowOffset = CGSize(width: 0, height: 6)
        pulse.removeAllAnimations()
        pulse.backgroundColor = Theme.rec.withAlphaComponent(0.45).cgColor
        pulse.isHidden = look != .recording
        if look == .recording {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = 1
            s.toValue = 1 + 32 / side
            let o = CABasicAnimation(keyPath: "opacity")
            o.fromValue = 1
            o.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [s, o]
            g.duration = 1.4
            g.repeatCount = .infinity
            pulse.add(g, forKey: "ring")
        }
    }
}

// MARK: - 声波

final class WaveView: UIView {
    var level: Float = 0
    private var bars: [CALayer] = []
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<22 {
            let b = CALayer()
            b.cornerRadius = 1.5
            layer.addSublayer(b)
            bars.append(b)
        }
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 22 * 6 - 3), heightAnchor.constraint(equalToConstant: 22)])
    }

    required init?(coder: NSCoder) { fatalError() }

    func run(_ on: Bool) {
        if on, link == nil {
            let l = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20)
            l.add(to: .main, forMode: .common)
            link = l
        } else if !on {
            link?.invalidate()
            link = nil
        }
        draw()
    }

    override func willMove(toWindow w: UIWindow?) {
        if w == nil { run(false) }
    }

    fileprivate func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let t = CACurrentMediaTime() * 1000 / 160
        let color = Theme.accent.resolvedColor(with: traitCollection).cgColor
        for (i, b) in bars.enumerated() {
            let h = link == nil ? 4 : 4 + abs(sin(Double(i) * 1.3 + t)) * 16 * (0.4 + Double(level) * 0.6)
            b.backgroundColor = color
            b.frame = CGRect(x: CGFloat(i) * 6, y: (22 - h) / 2, width: 3, height: h)
        }
        CATransaction.commit()
    }

    private final class WeakTarget: NSObject {
        weak var view: WaveView?
        init(_ v: WaveView) { view = v }
        @objc func tick() { view?.draw() }
    }
}

// MARK: - 按键

class KeyButton: UIButton {
    enum Style { case key, fn, enter, action, actionRec, actionOutline }

    var style: Style { didSet { setNeedsLayout() } }
    /// 不设则按样式取默认字号
    var fontSize: CGFloat? { didSet { setNeedsLayout() } }
    private let grad = Theme.gradientLayer()

    init(_ title: String? = nil, symbol: String? = nil, style: Style = .key) {
        self.style = style
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        if let symbol { setImage(Theme.symbol(symbol, 17), for: .normal) }
        titleLabel?.font = .systemFont(ofSize: 15)
        layer.cornerRadius = 6
        grad.cornerRadius = 6
        layer.insertSublayer(grad, at: 0)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        layer.shadowOpacity = 0.25
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: KeyButton, _) in v.setNeedsLayout() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }

    override func layoutSubviews() {
        super.layoutSubviews()
        let t = traitCollection
        grad.frame = bounds
        grad.isHidden = style != .action
        let fg: UIColor
        switch style {
        case .key: backgroundColor = Theme.key; fg = Theme.fg
        case .fn: backgroundColor = Theme.key2; fg = Theme.fg
        case .enter: backgroundColor = Theme.accent; fg = .white
        case .action: backgroundColor = .clear; fg = .white
        case .actionRec: backgroundColor = Theme.rec; fg = .white
        case .actionOutline: backgroundColor = Theme.key; fg = Theme.accent
        }
        // 富文本标题（中/英键）自带字体颜色，再设 titleLabel 会触发重新布局而死循环
        if attributedTitle(for: .normal) == nil {
            setTitleColor(fg, for: .normal)
            let plain = style == .key || style == .fn || style == .enter
            titleLabel?.font = .systemFont(ofSize: fontSize ?? (plain ? 15 : 13.5), weight: plain ? .regular : .semibold)
        }
        tintColor = fg
        layer.borderWidth = style == .actionOutline ? 1.5 : 0
        layer.borderColor = Theme.accent.resolvedColor(with: t).cgColor
    }
}

// MARK: - 提示条

final class NoteView: ThemedView {
    enum Kind { case err, warn, info }

    var onAction: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var kind = Kind.info
    private let text = Theme.label(12.5, lines: 3)
    private let action = UIButton(type: .system)
    private let close = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 10
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: 4)
        action.titleLabel?.font = .systemFont(ofSize: 12)
        action.layer.cornerRadius = 6
        action.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        action.contentEdgeInsets = UIEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        action.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .touchUpInside)
        close.setTitle("×", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 17)
        close.alpha = 0.6
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [text, action, close])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        action.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentHuggingPriority(.required, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            close.widthAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ kind: Kind, _ message: String, action title: String?) {
        self.kind = kind
        text.text = message
        action.setTitle(title, for: .normal)
        action.isHidden = title == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let (bg, fg): (UIColor, UIColor)
        switch kind {
        case .err: (bg, fg) = (Theme.dyn(Theme.hex(0xffe9eb), Theme.hex(0x4a1a20)), Theme.dyn(Theme.hex(0xa3121f), Theme.hex(0xffb3ba)))
        case .warn: (bg, fg) = (Theme.dyn(Theme.hex(0xfff3dc), Theme.hex(0x4a3410)), Theme.dyn(Theme.hex(0x7a4b00), Theme.hex(0xffd99a)))
        case .info: (bg, fg) = (Theme.dyn(.white, Theme.hex(0x1c1c1e)), Theme.fg)
        }
        backgroundColor = bg
        text.textColor = fg
        action.setTitleColor(fg, for: .normal)
        close.setTitleColor(fg, for: .normal)
    }
}

// MARK: - 候选框

final class CandidateRow: UIControl {
    let channel: String
    private let bar = UIView()
    private let dot = UIView()
    private let name = Theme.label(11.5, Theme.fg2)
    private let text = Theme.label(14.5, lines: 0)
    private let pend = Theme.label(10.5, Theme.accent)
    private let ms = Theme.label(11, Theme.fg3)
    private let spin = UIActivityIndicatorView(style: .medium)

    init(channel: String) {
        self.channel = channel
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "row-\(channel)"
        bar.backgroundColor = Theme.accent
        bar.layer.cornerRadius = 1.5
        dot.layer.cornerRadius = 3
        pend.text = "定稿后上屏"
        ms.textAlignment = .right
        ms.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        spin.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        let nameRow = UIStackView(arrangedSubviews: [dot, name])
        nameRow.spacing = 4
        nameRow.alignment = .center
        let mid = UIStackView(arrangedSubviews: [text, pend])
        mid.axis = .vertical
        let right = UIView()
        for v in [ms, spin] {
            v.translatesAutoresizingMaskIntoConstraints = false
            right.addSubview(v)
        }
        for v in [bar, nameRow, mid, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            bar.widthAnchor.constraint(equalToConstant: 3),
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            nameRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            nameRow.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            nameRow.widthAnchor.constraint(equalToConstant: 58),
            mid.leadingAnchor.constraint(equalTo: nameRow.trailingAnchor, constant: 8),
            mid.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            mid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            right.leadingAnchor.constraint(equalTo: mid.trailingAnchor, constant: 8),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            right.widthAnchor.constraint(equalToConstant: 40),
            right.heightAnchor.constraint(equalToConstant: 16),
            ms.trailingAnchor.constraint(equalTo: right.trailingAnchor), ms.centerYAnchor.constraint(equalTo: right.centerYAnchor),
            spin.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: 4), spin.centerYAnchor.constraint(equalTo: right.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.6 : 1 } }

    func update(_ r: LiveState.Row, selected: Bool, pending: Bool) {
        name.text = r.name
        dot.backgroundColor = switch r.state {
        case .listening: Theme.rec
        case .finalizing: Theme.warn
        case .final: Theme.ok
        case .error: Theme.err
        }
        if r.state == .error {
            text.text = "识别失败（\(r.error ?? "识别失败")）"
            text.textColor = Theme.err
            text.font = .systemFont(ofSize: 13)
        } else if r.text.isEmpty {
            text.text = r.state == .final ? "（没有识别到内容）" : "…"
            text.textColor = Theme.fg3
            text.font = .systemFont(ofSize: 13)
        } else {
            text.text = r.text
            text.textColor = Theme.fg
            text.font = .systemFont(ofSize: 14.5)
        }
        pend.isHidden = !pending
        backgroundColor = selected ? Theme.accent.withAlphaComponent(0.14) : .clear
        bar.isHidden = !selected
        if r.state == .finalizing { spin.startAnimating() } else { spin.stopAnimating() }
        ms.text = r.state == .finalizing ? nil : r.ms.map { String(format: "%.2fs", Double($0) / 1000) }
        accessibilityLabel = "\(r.name)：\(text.text ?? "")"
        accessibilityValue = pending ? "定稿后上屏" : ms.text
    }
}

final class CandidatePanel: ThemedView {
    var onPick: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?
    private let recDot = UIView()
    private let spin = UIActivityIndicatorView(style: .medium)
    private let status = Theme.label(12, Theme.fg2)
    private let retry = UIButton(type: .system)
    private let hint = Theme.label(12, Theme.fg3)
    private let close = UIButton(type: .system)
    private let list = UIStackView()
    private let scroll = UIScrollView()
    private var rows: [CandidateRow] = []
    private var seps: [UIView] = []
    private let headerLine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.key
        layer.cornerRadius = 10
        clipsToBounds = true
        recDot.backgroundColor = Theme.rec
        recDot.layer.cornerRadius = 3.5
        spin.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        retry.setTitle("重试", for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 12)
        retry.tintColor = Theme.accent
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        hint.text = "可提前选"
        close.setTitle("✕", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 14)
        close.tintColor = Theme.fg2
        close.backgroundColor = Theme.line
        close.layer.cornerRadius = 7
        close.accessibilityLabel = "关闭候选"
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let head = UIStackView(arrangedSubviews: [recDot, spin, status, retry, spacer, hint, close])
        head.spacing = 8
        head.alignment = .center
        headerLine.backgroundColor = Theme.line
        list.axis = .vertical
        scroll.alwaysBounceVertical = false
        for v in [head, headerLine, scroll, list] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(head)
        addSubview(headerLine)
        addSubview(scroll)
        scroll.addSubview(list)
        NSLayoutConstraint.activate([
            recDot.widthAnchor.constraint(equalToConstant: 7), recDot.heightAnchor.constraint(equalToConstant: 7),
            spin.widthAnchor.constraint(equalToConstant: 14),
            close.widthAnchor.constraint(equalToConstant: 26), close.heightAnchor.constraint(equalToConstant: 26),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            head.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            headerLine.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 4),
            headerLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerLine.heightAnchor.constraint(equalToConstant: 0.5),
            scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ u: LiveState.Utterance, selected: String?, pending: String?) {
        if rows.map(\.channel) != u.rows.map(\.channel) {
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            rows = u.rows.map { r in
                let v = CandidateRow(channel: r.channel)
                v.addAction(UIAction { [weak self] _ in self?.onPick?(r.channel) }, for: .touchUpInside)
                return v
            }
            for (i, v) in rows.enumerated() {
                if i > 0 {
                    let s = UIView()
                    s.backgroundColor = Theme.line
                    s.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                    list.addArrangedSubview(s)
                }
                list.addArrangedSubview(v)
            }
        }
        for (v, r) in zip(rows, u.rows) { v.update(r, selected: r.channel == selected, pending: r.channel == pending) }
        let recording = u.phase == .recording
        recDot.isHidden = !recording
        hint.isHidden = !recording
        let finalizing = u.phase == .finalizing
        spin.isHidden = !finalizing
        if finalizing { spin.startAnimating() } else { spin.stopAnimating() }
        let failed = u.rows.contains { $0.state == .error }
        retry.isHidden = !(u.phase == .done && failed && u.retryable)
        if recording {
            status.text = "聆听中 · 点按结束"
            status.textColor = Theme.fg2
        } else if finalizing {
            status.text = "定稿中 \(u.rows.filter { $0.state == .final || $0.state == .error }.count)/\(u.rows.count)"
            status.textColor = Theme.fg2
        } else if u.rows.allSatisfy({ $0.state == .error }) {
            status.text = "全部失败"
            status.textColor = Theme.err
        } else {
            status.text = "● 全部完成 · 点一条上屏"
            status.textColor = Theme.ok
        }
        recDot.layer.removeAllAnimations()
        if recording {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.35
            a.duration = 0.6
            a.autoreverses = true
            a.repeatCount = .infinity
            recDot.layer.add(a, forKey: "pulse")
        }
    }
}

// MARK: - 底部弹层（渠道 / 最近上屏）

final class SheetView: ThemedView {
    let content = UIStackView()
    var onDone: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = Theme.kb
        let t = Theme.label(14, weight: .semibold)
        t.text = title
        let done = UIButton(type: .system)
        done.setTitle("完成", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 14)
        done.tintColor = Theme.accent
        done.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        let head = UIStackView(arrangedSubviews: [t, UIView(), done])
        let scroll = UIScrollView()
        content.axis = .vertical
        content.spacing = 6
        for v in [head, scroll, content] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(head)
        addSubview(scroll)
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            head.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func section(_ text: String) {
        let l = Theme.label(12, Theme.fg3, lines: 0)
        l.text = text
        let wrap = UIStackView(arrangedSubviews: [l])
        wrap.isLayoutMarginsRelativeArrangement = true
        wrap.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 0, trailing: 6)
        content.addArrangedSubview(wrap)
    }

    func group(_ cells: [UIView]) {
        let g = UIStackView()
        g.axis = .vertical
        g.backgroundColor = Theme.key
        g.layer.cornerRadius = 10
        g.clipsToBounds = true
        for (i, c) in cells.enumerated() {
            if i > 0 {
                let s = UIView()
                s.backgroundColor = Theme.line
                s.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                g.addArrangedSubview(s)
            }
            g.addArrangedSubview(c)
        }
        content.addArrangedSubview(g)
    }

    static func cell(_ title: String, sub: String? = nil, accessory: UIView? = nil, lines: Int = 1, tap: (() -> Void)? = nil) -> UIView {
        let c = UIControl()
        let t = Theme.label(15, lines: lines)
        t.text = title
        let col = UIStackView(arrangedSubviews: [t])
        col.axis = .vertical
        col.spacing = 2
        if let sub {
            let s = Theme.label(12, Theme.fg3, lines: 2)
            s.text = sub
            col.addArrangedSubview(s)
        }
        let row = UIStackView(arrangedSubviews: [col] + (accessory.map { [$0] } ?? []))
        row.spacing = 10
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        row.isUserInteractionEnabled = accessory is UISwitch
        c.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: c.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -10),
            c.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        if let tap { c.addAction(UIAction { _ in tap() }, for: .touchUpInside) }
        return c
    }

    static func check(_ on: Bool) -> UIView {
        let l = Theme.label(15, Theme.accent, weight: .bold)
        l.text = on ? "✓" : ""
        l.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return l
    }
}
