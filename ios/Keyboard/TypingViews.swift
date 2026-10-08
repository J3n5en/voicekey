import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 打字按键区：26 键（字母、数字、符号页）与九宫格，尺寸对照 iOS 26 系统拼音键盘（440pt 宽机型实测）
final class KeyPad: UIView {
    enum Page { case abc, num, sym }

    enum Key: Equatable {
        case letter(Character), digit(Character), one, text(String)
        case space, back, enter, globe, shift, lang, page(Page)
    }

    struct Spec: Equatable {
        var t9 = false
        var zh = true
        var page = Page.abc
        var shift = false
        /// 系统没在键盘下方提供 🌐 时（Home 键机型等）才在键盘里放
        var globe = true
    }

    /// sys：Shift / 删除 / 123 等功能键；enter：底行换行键（宽度按原生比例由布局算出）
    private enum Width { case unit, fixed(CGFloat), flex, sys, enter }

    private struct Item {
        let key: Key
        let button: KeyButton
        var width = Width.unit
        /// 与下一个键之间额外的间距
        var extra: CGFloat = 0
        /// 九宫格位置
        var cell: Cell?
    }

    /// 九宫格 5 列 × 4 行网格中的位置：起始列（可为半列）、行、占几列、占几行
    private struct Cell {
        var c: CGFloat
        var r: Int
        var cw: CGFloat = 1
        var rh = 1
    }

    /// 系统键盘的键圆角
    static let radius: CGFloat = 8.5

    var onKey: ((Key) -> Void)?
    /// 九宫格左列：组字中为拼音，空闲时为标点
    var onList: ((String, _ pinyin: Bool) -> Void)?
    /// 🌐 仍是真按钮（系统切换输入法要 UIEvent），由控制器接上
    var wire: ((KeyButton, Key) -> Void)?
    /// 空格、删除的触摸阶段交给控制器（长按移光标、连删、上滑清空）；phase 可能是补发的 ended / cancelled
    var onTrack: ((KeyButton, Key, UITouch.Phase, UITouch) -> Void)?
    /// 每次按下一个键：按键音、震动
    var onFeedback: (() -> Void)?

    private(set) var spec = Spec()
    private var built: Spec?
    private var rows: [[Item]] = []
    private(set) var space: KeyButton?
    private var enter: KeyButton?
    private var oneKey: DigitKey?
    private let list = SideList()
    private var listCell = false

    /// 九宫格左列空闲时的中文标点（待定点 2：中文标点放左列）
    static let t9Punct = ["，", "。", "？", "！", "、", "：", "；", "…", "～", "“", "”"]
    static let t9Math = ["+", "-", "*", "/", "=", "%", "@", ":", "(", ")", "#", "~"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        list.onTap = { [weak self] in self?.onList?($0, $1) }
        // 键盘扩展里完全透明的点收不到触摸，键缝要能按就得有一点底色
        backgroundColor = UIColor.black.withAlphaComponent(0.001)
        isMultipleTouchEnabled = true
        let tracker = TouchTracker()
        tracker.onBegan = { [weak self] in self?.began($0) }
        tracker.onMoved = { [weak self] in self?.moved($0) }
        tracker.onEnded = { [weak self] in self?.ended($0, cancelled: $1) }
        addGestureRecognizer(tracker)
        addSubview(popup)
    }

    required init?(coder: NSCoder) { fatalError() }

    var keys: [KeyButton] { rows.flatMap { $0.map(\.button) } }
    var sideList: UIView { list }

    func set(_ s: Spec) {
        spec = s
        guard built != s else { return }
        built = s
        rows.flatMap { $0 }.forEach { $0.button.removeFromSuperview() }
        hidePopup()
        rows = s.t9 && s.page != .sym ? t9Rows(s) : qwertyRows(s)
        listCell = s.t9 && s.page != .sym
        if listCell { addSubview(list) } else { list.removeFromSuperview() }
        for it in rows.joined() {
            it.button.isUserInteractionEnabled = it.key == .globe
            addSubview(it.button)
        }
        if s.t9, s.page == .num { list.set(Self.t9Math, pinyin: false) }
        setNeedsLayout()
    }

    /// 每次按键后刷新会变的部分
    func update(composing: Bool, pinyin: [String]) {
        space?.setTitle(composing ? "首选词" : "空格", for: .normal)
        space?.accessibilityHint = composing ? "选择首选词" : "长按移动光标"
        enter?.setTitle(composing ? "确认" : "换行", for: .normal)
        oneKey?.bottom.text = composing ? "分词" : "@/."
        if spec.t9, spec.page == .abc { list.set(composing ? pinyin : Self.t9Punct, pinyin: composing) }
    }

    // MARK: 键位

    private func make(_ key: Key) -> KeyButton {
        let b: KeyButton
        switch key {
        case .letter(let c):
            let t = spec.shift && !spec.zh ? c.uppercased() : String(c)
            b = KeyButton(t, style: .key)
            b.fontSize = 23
            b.accessibilityLabel = String(c)
        case .digit(let c):
            let d = DigitKey(String(c), Self.t9Letters[c] ?? "")
            d.accessibilityLabel = String(c)
            b = d
        case .one:
            let d = DigitKey("1", "@/.")
            d.accessibilityLabel = "1"
            oneKey = d
            b = d
        case .text(let s):
            b = KeyButton(s, style: .key)
            b.fontSize = s.count == 1 && s.first!.isNumber ? 23 : 20
            b.accessibilityLabel = s
        case .space:
            b = KeyButton("空格", style: .key)
            b.fontSize = 16
            b.accessibilityIdentifier = "空格"
            space = b
        case .back:
            b = KeyButton(symbol: "delete.left", style: .key)
            b.accessibilityLabel = "删除"
        case .enter:
            b = KeyButton("换行", style: .key)
            b.fontSize = 16
            b.accessibilityIdentifier = "换行"
            enter = b
        case .globe:
            b = KeyButton(symbol: "globe", style: .key)
            b.accessibilityLabel = "切换输入法"
        case .shift:
            b = KeyButton(symbol: spec.shift ? "shift.fill" : "shift", style: .key)
            b.accessibilityLabel = "大写"
        case .lang:
            b = KeyButton(nil, style: .key)
            let on = UIFont.systemFont(ofSize: 16), off = UIFont.systemFont(ofSize: 12)
            let t = NSMutableAttributedString()
            t.append(NSAttributedString(string: spec.zh ? "中" : "中/", attributes: [.font: spec.zh ? on : off, .foregroundColor: spec.zh ? Theme.fg : Theme.fg3]))
            t.append(NSAttributedString(string: spec.zh ? "/英" : "英", attributes: [.font: spec.zh ? off : on, .foregroundColor: spec.zh ? Theme.fg3 : Theme.fg]))
            b.setAttributedTitle(t, for: .normal)
            b.accessibilityLabel = "中英切换"
            b.accessibilityValue = spec.zh ? "中文" : "英文"
        case .page(let p):
            let title: String
            switch p {
            case .abc: title = spec.t9 && spec.page == .num ? "返回" : "ABC"
            case .num: title = "123"
            case .sym: title = spec.t9 ? "符" : "#+="
            }
            b = KeyButton(title, style: .key)
            b.fontSize = 16
        }
        // iOS 26 系统键盘：功能键与字母键同为白底、大圆角
        b.layer.cornerRadius = Self.radius
        if key == .globe { wire?(b, key) } else { b.activate = { [weak self] in self?.onKey?(key) } }
        return b
    }

    private func item(_ key: Key, _ w: Width = .unit, extra: CGFloat = 0, size: CGFloat? = nil) -> Item {
        let b = make(key)
        if let size { b.fontSize = size }
        return Item(key: key, button: b, width: w, extra: extra)
    }

    private func qwertyRows(_ s: Spec) -> [[Item]] {
        let zh = s.zh
        func letters(_ x: String) -> [Item] { x.map { item(.letter($0)) } }
        func texts(_ a: [String]) -> [Item] { a.map { item(.text($0)) } }
        var r: [[Item]]
        switch s.page {
        case .abc:
            let lead = zh ? item(.letter("'"), .sys) : item(.shift, .sys)
            r = [letters("qwertyuiop"), letters("asdfghjkl"), [lead] + letters("zxcvbnm") + [item(.back, .sys)]]
        case .num, .sym:
            let num = s.page == .num
            let row1 = num ? "1234567890".map(String.init) : ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
            let row2 = num ? (zh ? ["，", "。", "？", "！", "、", "：", "；", "（", "）", "@"] : ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""])
                : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
            let row3 = zh ? ["…", "—", "《", "》", "“", "”", "·"] : [".", ",", "?", "!", "'", "-", "…"]
            r = [texts(row1), texts(row2), [item(.page(num ? .sym : .num), .sys)] + texts(row3) + [item(.back, .sys)]]
        }
        // 底行：123 | (🌐) | 中/英 | ， | 空格 | 。 | 换行
        var bottom = [item(.page(s.page == .abc ? .num : .abc), .sys)]
        if s.globe { bottom.append(item(.globe)) }
        bottom += [
            item(.lang, .sys),
            item(.text(zh ? "，" : ","), size: 20),
            item(.space, .flex),
            item(.text(zh ? "。" : "."), size: 20),
            item(.enter, .enter),
        ]
        r.append(bottom)
        return r
    }

    private static let t9Letters: [Character: String] = ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ"]

    /// 与系统九宫格一致的 5 列 × 4 行：左列（前三行为标点/拼音列表）、中间 3 列、右列 ⌫ / 0 / 换行（换行占两行）
    private func t9Rows(_ s: Spec) -> [[Item]] {
        func at(_ key: Key, _ c: CGFloat, _ r: Int, cw: CGFloat = 1, rh: Int = 1) -> Item {
            var i = item(key)
            i.cell = Cell(c: c, r: r, cw: cw, rh: rh)
            return i
        }
        // 底行左列：123（Home 键机型再与 🌐 平分）
        func lead(_ p: Page) -> [Item] {
            s.globe ? [at(.page(p), 0, 3, cw: 0.5), at(.globe, 0.5, 3, cw: 0.5)] : [at(.page(p), 0, 3)]
        }
        var g: [Item]
        if s.page == .num {
            g = (1...9).map { n in at(.text(String(n)), CGFloat((n - 1) % 3 + 1), (n - 1) / 3) }
            g += [at(.back, 4, 0), at(.text("."), 4, 1), at(.enter, 4, 2, rh: 2)]
            g += lead(.abc) + [at(.page(.sym), 1, 3), at(.text("0"), 2, 3), at(.space, 3, 3)]
        } else {
            g = [at(.one, 1, 0)] + (2...9).map { n in at(.digit(Character(String(n))), CGFloat((n - 1) % 3 + 1), (n - 1) / 3) }
            // 待定点 4：0 单独一个键，放在 ⌫ 下面
            g += [at(.back, 4, 0), at(.text("0"), 4, 1), at(.enter, 4, 2, rh: 2)]
            g += lead(.num) + [at(.lang, 1, 3), at(.space, 2, 3, cw: 2)]
        }
        return [g]
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        if listCell { layoutT9() } else { layoutQwerty() }
    }

    /// 系统 26 键：键高 42、行距 14，键距约为宽度的 2%（440pt 上 9），第二行缩进半格，
    /// 第三行 Shift / 删除贴边（约 1.33 键宽）、字母居中；底行 123 与中/英同 Shift 宽，换行约 23.5% 宽
    private func layoutQwerty() {
        let w = bounds.width, h = bounds.height, pad: CGFloat = 2.5
        let gap = (w * 0.0205).rounded(), bgap = (gap * 0.75).rounded()
        let unit = (w - 2 * pad - 9 * gap) / 10, slot = unit + gap
        let sys = (unit * 1.33).rounded()
        let n = CGFloat(rows.count)
        let vgap: CGFloat = h > 200 ? 14 : 8
        let rowH = min(42, floor((h - 8 - (n - 1) * vgap) / n))
        let y0 = (h - n * rowH - (n - 1) * vgap) / 2
        for (i, row) in rows.enumerated() {
            let y = y0 + CGFloat(i) * (rowH + vgap)
            if row.contains(where: { if case .flex = $0.width { return true }; return false }) {
                place(row, x0: pad, width: w - 2 * pad, y: y, h: rowH, unit: unit, gap: bgap, sys: sys, enter: (w * 0.235).rounded())
            } else if case .sys = row.first?.width, row.count > 2 {
                // 功能键贴两边，中间字母按格居中
                let mid = row.count - 2
                var x = (w - CGFloat(mid) * slot + gap) / 2
                row[0].button.frame = CGRect(x: pad, y: y, width: sys, height: rowH)
                row[row.count - 1].button.frame = CGRect(x: w - pad - sys, y: y, width: sys, height: rowH)
                for it in row[1...mid] {
                    it.button.frame = CGRect(x: x, y: y, width: unit, height: rowH)
                    x += slot
                }
            } else {
                var x = (w - CGFloat(row.count) * slot + gap) / 2
                for it in row {
                    it.button.frame = CGRect(x: x, y: y, width: unit, height: rowH)
                    x += slot
                }
            }
        }
    }

    /// 系统九宫格：5 列等宽、键距 6，键高 45、行距 11
    private func layoutT9() {
        let w = bounds.width, h = bounds.height, pad: CGFloat = 2.5, gap: CGFloat = 6
        let col = (w - 2 * pad - 4 * gap) / 5
        let vgap: CGFloat = h > 200 ? 11 : 6
        let rowH = min(45, floor((h - 8 - 3 * vgap) / 4))
        let y0 = (h - 4 * rowH - 3 * vgap) / 2
        func frame(_ c: Cell) -> CGRect {
            CGRect(x: pad + c.c * (col + gap), y: y0 + CGFloat(c.r) * (rowH + vgap),
                   width: c.cw * col + (c.cw - 1) * gap, height: CGFloat(c.rh) * rowH + CGFloat(c.rh - 1) * vgap)
        }
        list.frame = frame(Cell(c: 0, r: 0, rh: 3))
        for it in rows.flatMap({ $0 }) {
            if let c = it.cell { it.button.frame = frame(c) }
        }
    }

    private func place(_ row: [Item], x0: CGFloat, width: CGFloat, y: CGFloat, h: CGFloat, unit: CGFloat, gap: CGFloat,
                       sys: CGFloat = 44, enter: CGFloat = 88) {
        func size(_ wd: Width) -> CGFloat? {
            switch wd {
            case .unit: return unit
            case .fixed(let f): return f
            case .sys: return sys
            case .enter: return enter
            case .flex: return nil
            }
        }
        var fixed: CGFloat = 0, flex = 0
        for (i, it) in row.enumerated() {
            if let s = size(it.width) { fixed += s } else { flex += 1 }
            if i < row.count - 1 { fixed += gap + it.extra }
        }
        let flexW = flex > 0 ? (width - fixed) / CGFloat(flex) : 0
        var x = flex > 0 ? x0 : x0 + (width - fixed) / 2
        for it in row {
            let wd = size(it.width) ?? flexW
            it.button.frame = CGRect(x: x, y: y, width: wd, height: h)
            x += wd + gap + it.extra
        }
    }

    // MARK: 触摸
    // 整块按键区统一收触摸，落点算到最近的键（键缝、边缘不再是死区）；
    // 按下即反馈、松手上屏；新手指按下时先把还按着的键上屏（快速双拇指交替不丢字、不乱序）。

    private final class Track {
        var key: Key
        var button: KeyButton
        let wired: Bool
        weak var touch: UITouch?

        init(_ item: Item, touch: UITouch) {
            key = item.key
            button = item.button
            wired = item.key == .space || item.key == .back
            self.touch = touch
        }
    }

    private var tracks: [(id: ObjectIdentifier, t: Track)] = []
    private let popup = KeyPopup()
    private weak var popupOwner: Track?

    private func nearest(_ p: CGPoint) -> Item? {
        var best: Item?, bd = CGFloat.greatestFiniteMagnitude
        for it in rows.joined() where !it.button.isHidden {
            let f = it.button.frame
            let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
            let d = dx * dx + dy * dy
            if d < bd { bd = d; best = it }
        }
        return best
    }

    private func inList(_ p: CGPoint) -> Bool { listCell && list.frame.insetBy(dx: -3, dy: -3).contains(p) }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01, self.point(inside: point, with: event) else { return nil }
        if inList(point) { return list.hitTest(convert(point, to: list), with: event) ?? list }
        if let it = nearest(point), it.key == .globe { return it.button }
        return self
    }

    private func track(_ touch: UITouch) -> Track? {
        tracks.first { $0.id == ObjectIdentifier(touch) }?.t
    }

    private func began(_ touch: UITouch) {
        rollover()
        let p = touch.location(in: self)
        guard !inList(p), let it = nearest(p), it.key != .globe else { return }
        let t = Track(it, touch: touch)
        tracks.append((ObjectIdentifier(touch), t))
        onFeedback?()
        if t.wired { onTrack?(t.button, t.key, .began, touch) } else { show(t, down: true) }
    }

    private func moved(_ touch: UITouch) {
        guard let t = track(touch) else { return }
        if t.wired { return onTrack?(t.button, t.key, .moved, touch) ?? () }
        let p = touch.location(in: self)
        // 出了当前键（再宽 4pt）才换键，快打时手指轻微搓动不跳键
        if t.button.superview === self, t.button.frame.insetBy(dx: -4, dy: -4).contains(p) { return }
        guard let it = nearest(p), it.button !== t.button, it.key != .globe, it.key != .space, it.key != .back else { return }
        show(t, down: false)
        t.key = it.key
        t.button = it.button
        show(t, down: true)
    }

    private func ended(_ touch: UITouch, cancelled: Bool) {
        guard let i = tracks.firstIndex(where: { $0.id == ObjectIdentifier(touch) }) else { return }
        finish(tracks.remove(at: i).t, cancelled: cancelled)
    }

    /// 新手指按下：还按着的键先上屏；空格按松手处理，删除停止连删
    private func rollover() {
        let pending = tracks
        tracks = []
        for (_, t) in pending { finish(t, cancelled: t.key == .back) }
    }

    private func finish(_ t: Track, cancelled: Bool) {
        if t.wired {
            if let touch = t.touch { onTrack?(t.button, t.key, cancelled ? .cancelled : .ended, touch) }
            return
        }
        show(t, down: false)
        if !cancelled { onKey?(t.key) }
    }

    /// 按下态：键变色；26 键的字母、符号键弹出放大字
    private func show(_ t: Track, down: Bool) {
        // 换过页（Shift、123）后旧按钮已移除，按键值找新按钮
        let b = t.button.superview === self ? t.button : rows.joined().first { $0.key == t.key }?.button
        b?.isHighlighted = down
        if down, let b, !listCell, Self.pops(t.key) {
            popupOwner = t
            popup.show(b.title(for: .normal) ?? "", over: b.frame, in: bounds)
            bringSubviewToFront(popup)
        } else if !down, popupOwner === t {
            hidePopup()
        }
    }

    private func hidePopup() {
        popup.isHidden = true
        popupOwner = nil
    }

    private static func pops(_ k: Key) -> Bool {
        switch k {
        case .letter, .text: return true
        default: return false
        }
    }
}

/// 系统键盘式的按键放大气泡：上方放大字，下方连着按下的键
final class KeyPopup: UIView {
    private let shape = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        layer.zPosition = 10
        shape.shadowColor = UIColor.black.cgColor
        shape.shadowOpacity = 0.3
        shape.shadowRadius = 1.5
        shape.shadowOffset = CGSize(width: 0, height: 0.5)
        layer.addSublayer(shape)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 34)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, over k: CGRect, in area: CGRect) {
        let bw = k.width + 22, bh = (k.height * 1.15).rounded()
        let x = min(max(k.midX - bw / 2, area.minX), area.maxX - bw)
        let y = k.minY - bh + 2
        frame = CGRect(x: x, y: y, width: bw, height: k.maxY - y)
        let stem = CGRect(x: k.minX - x, y: bh - 14, width: k.width, height: frame.height - bh + 14)
        let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: bw, height: bh), cornerRadius: 11)
        path.append(UIBezierPath(roundedRect: stem, cornerRadius: KeyPad.radius))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path.cgPath
        shape.shadowPath = path.cgPath
        shape.fillColor = Theme.key.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
        label.text = text
        label.textColor = Theme.fg
        label.frame = CGRect(x: 0, y: 0, width: bw, height: bh - 6)
        isHidden = false
    }
}

/// 只观察不拦截的触摸跟踪：手势识别器不受屏幕边缘系统手势的延迟，按键区左右两边的键也即按即响
private final class TouchTracker: UIGestureRecognizer {
    var onBegan: ((UITouch) -> Void)?
    var onMoved: ((UITouch) -> Void)?
    var onEnded: ((UITouch, _ cancelled: Bool) -> Void)?
    private var live = Set<ObjectIdentifier>()

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            live.insert(ObjectIdentifier(t))
            onBegan?(t)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        touches.forEach { onMoved?($0) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { end(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { end(touches, cancelled: true) }

    private func end(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            live.remove(ObjectIdentifier(t))
            onEnded?(t, cancelled)
        }
        // 所有手指都抬起才收尾，多指交替时一直在跟踪
        if live.isEmpty { state = .failed }
    }

    override func reset() { live.removeAll() }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// 九宫格字母键：同系统只显示字母（加字距），数字仅用于无障碍
final class DigitKey: KeyButton {
    let bottom = Theme.label(18)

    init(_ digit: String, _ letters: String) {
        super.init(nil, style: .key)
        let t = NSMutableAttributedString(string: letters)
        if letters.count > 1 { t.addAttribute(.kern, value: 2, range: NSRange(location: 0, length: (letters as NSString).length - 1)) }
        bottom.attributedText = t
        bottom.isUserInteractionEnabled = false
        bottom.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottom)
        bottom.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        bottom.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// 九宫格左列：可滚动的一列按钮，按钮复用
final class SideList: UIScrollView {
    var onTap: ((String, Bool) -> Void)?
    private var pool: [UIButton] = []
    private var items: [String] = []
    private var pinyin = false
    private let empty = Theme.label(15, Theme.fg3)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = KeyPad.radius
        showsVerticalScrollIndicator = false
        empty.text = "—"
        empty.textAlignment = .center
        addSubview(empty)
        accessibilityIdentifier = "t9-list"
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ items: [String], pinyin: Bool) {
        guard items != self.items || pinyin != self.pinyin else { return }
        self.items = items
        self.pinyin = pinyin
        backgroundColor = Theme.key
        while pool.count < items.count {
            let b = UIButton(type: .custom)
            b.setTitleColor(Theme.fg, for: .normal)
            b.setBackgroundImage(UIImage.pixel(Theme.line), for: .highlighted)
            b.addAction(UIAction { [weak self, weak b] _ in
                guard let self, let b, let i = self.pool.firstIndex(of: b), i < self.items.count else { return }
                self.onTap?(self.items[i], self.pinyin)
            }, for: .touchUpInside)
            let line = UIView()
            line.backgroundColor = Theme.line
            line.tag = 1
            b.addSubview(line)
            pool.append(b)
            addSubview(b)
        }
        for (i, b) in pool.enumerated() {
            b.isHidden = i >= items.count
            guard i < items.count else { continue }
            b.setTitle(items[i], for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: pinyin ? 14 : 15, weight: i == 0 ? .semibold : .regular)
            b.accessibilityLabel = items[i]
        }
        empty.isHidden = !(pinyin && items.isEmpty)
        contentOffset = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h: CGFloat = 34, w = bounds.width
        for (i, b) in pool.enumerated() where i < items.count {
            b.frame = CGRect(x: 0, y: CGFloat(i) * h, width: w, height: h)
            b.viewWithTag(1)?.frame = CGRect(x: 0, y: h - 0.5, width: w, height: 0.5)
        }
        empty.frame = CGRect(x: 0, y: 10, width: w, height: 20)
        contentSize = CGSize(width: w, height: CGFloat(items.count) * h)
    }
}

/// 组字时替换顶部工具栏：上行拼音预览，下行候选（按钮复用），右侧展开
final class CompBar: UIView {
    var onPick: ((Int) -> Void)?
    var onMore: (() -> Void)?
    let preedit = UILabel()
    private let scroll = UIScrollView()
    private let more = UIButton(type: .system)
    private let divider = UIView()
    private var pool: [UIButton] = []
    private var count = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        preedit.font = .systemFont(ofSize: 12.5)
        preedit.lineBreakMode = .byTruncatingHead
        preedit.accessibilityIdentifier = "preedit"
        scroll.showsHorizontalScrollIndicator = false
        more.tintColor = Theme.fg2
        more.addAction(UIAction { [weak self] _ in self?.onMore?() }, for: .touchUpInside)
        divider.backgroundColor = Theme.line
        [preedit, scroll, more, divider].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(confirmed: String, picked: [String], guess: [String], candidates: [String], expanded: Bool) {
        let t = NSMutableAttributedString(string: confirmed, attributes: [.foregroundColor: Theme.fg, .font: UIFont.systemFont(ofSize: 12.5, weight: .medium)])
        let plain: [NSAttributedString.Key: Any] = [.foregroundColor: Theme.fg2, .font: UIFont.systemFont(ofSize: 12.5)]
        if !picked.isEmpty {
            t.append(NSAttributedString(string: picked.joined(separator: "'"), attributes: [.foregroundColor: Theme.accent, .font: UIFont.systemFont(ofSize: 12.5)]))
            if !guess.isEmpty { t.append(NSAttributedString(string: "'", attributes: plain)) }
        }
        t.append(NSAttributedString(string: guess.joined(separator: "'"), attributes: plain))
        preedit.attributedText = t
        preedit.accessibilityLabel = t.string

        more.setImage(Theme.symbol(expanded ? "chevron.up" : "chevron.down", 14), for: .normal)
        more.accessibilityLabel = expanded ? "收起候选" : "更多候选"
        scroll.isHidden = expanded
        count = candidates.count
        while pool.count < count {
            let b = UIButton(type: .custom)
            let i = pool.count
            b.accessibilityIdentifier = "cand\(i)"
            b.setBackgroundImage(UIImage.pixel(Theme.key2), for: .highlighted)
            b.layer.cornerRadius = 6
            b.clipsToBounds = true
            b.addAction(UIAction { [weak self] _ in self?.onPick?(i) }, for: .touchUpInside)
            pool.append(b)
            scroll.addSubview(b)
        }
        var x: CGFloat = 0
        for (i, b) in pool.enumerated() {
            b.isHidden = i >= count
            guard i < count else { continue }
            let font = UIFont.systemFont(ofSize: 18, weight: i == 0 ? .semibold : .regular)
            b.setAttributedTitle(NSAttributedString(string: candidates[i], attributes: [.font: font, .foregroundColor: i == 0 ? Theme.accent : Theme.fg]), for: .normal)
            b.accessibilityLabel = candidates[i]
            let w = ceil((candidates[i] as NSString).size(withAttributes: [.font: font]).width) + 18
            b.frame = CGRect(x: x, y: 0, width: w, height: 28)
            x += w + 2
        }
        scroll.contentSize = CGSize(width: x, height: 28)
        scroll.contentOffset = .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        preedit.frame = CGRect(x: 10, y: 2, width: w - 20, height: 16)
        scroll.frame = CGRect(x: 2, y: 16, width: w - 2 - 38, height: 28)
        more.frame = CGRect(x: w - 36, y: 17, width: 36, height: 26)
        divider.frame = CGRect(x: w - 36, y: 19, width: 0.5, height: 22)
    }
}

/// 展开的候选：四列网格（单元复用、滚到底再取下一批），右侧收起 / 重输 / ⌫
final class CandidateGrid: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var source: ((_ from: Int, _ limit: Int) -> [String])?
    var onPick: ((Int) -> Void)?
    var onCollapse: (() -> Void)?
    var onRetype: (() -> Void)?
    let back = KeyButton(symbol: "delete.left", style: .fn)
    private let grid: UICollectionView
    private var items: [String] = []
    private var exhausted = false
    private let batch = 60
    private let side = UIStackView()

    override init(frame: CGRect) {
        let flow = UICollectionViewFlowLayout()
        flow.minimumLineSpacing = 0
        flow.minimumInteritemSpacing = 0
        grid = UICollectionView(frame: .zero, collectionViewLayout: flow)
        super.init(frame: frame)
        grid.backgroundColor = Theme.key
        grid.layer.cornerRadius = 8
        grid.dataSource = self
        grid.delegate = self
        grid.register(Cell.self, forCellWithReuseIdentifier: "c")
        grid.accessibilityIdentifier = "cand-grid"
        let collapse = KeyButton("收起", style: .fn)
        collapse.fontSize = 14
        collapse.addAction(UIAction { [weak self] _ in self?.onCollapse?() }, for: .touchUpInside)
        let retype = KeyButton("重输", style: .fn)
        retype.fontSize = 14
        retype.addAction(UIAction { [weak self] _ in self?.onRetype?() }, for: .touchUpInside)
        back.accessibilityLabel = "删除"
        side.addArrangedSubview(collapse)
        side.addArrangedSubview(retype)
        side.addArrangedSubview(back)
        side.axis = .vertical
        side.spacing = 6
        side.distribution = .fillEqually
        addSubview(grid)
        addSubview(side)
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        items = source?(0, batch) ?? []
        exhausted = items.count < batch
        grid.reloadData()
        grid.contentOffset = .zero
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = bounds.inset(by: UIEdgeInsets(top: 4, left: 4, bottom: 6, right: 4))
        grid.frame = CGRect(x: r.minX, y: r.minY, width: r.width - 64, height: r.height)
        side.frame = CGRect(x: r.maxX - 58, y: r.minY, width: 58, height: r.height)
        grid.collectionViewLayout.invalidateLayout()
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "c", for: ip) as! Cell
        c.set(items[ip.item], first: ip.item == 0)
        if !exhausted, ip.item >= items.count - 12 {
            let more = source?(items.count, batch) ?? []
            exhausted = more.count < batch
            if !more.isEmpty {
                let start = items.count
                items += more
                DispatchQueue.main.async { cv.insertItems(at: (start..<start + more.count).map { IndexPath(item: $0, section: 0) }) }
            }
        }
        return c
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt ip: IndexPath) -> CGSize {
        let col = floor(cv.bounds.width / 4)
        let w = (items[ip.item] as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 18)]).width + 16
        return CGSize(width: col * min(4, ceil(w / col)), height: 44)
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) { onPick?(ip.item) }

    private final class Cell: UICollectionViewCell {
        private let label = UILabel()
        private let right = UIView()
        private let bottom = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            right.backgroundColor = Theme.line
            bottom.backgroundColor = Theme.line
            [label, right, bottom].forEach(contentView.addSubview)
            selectedBackgroundView = UIView()
            selectedBackgroundView?.backgroundColor = Theme.key2
            isAccessibilityElement = true
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError() }

        func set(_ text: String, first: Bool) {
            label.text = text
            label.font = .systemFont(ofSize: 18, weight: first ? .semibold : .regular)
            label.textColor = first ? Theme.accent : Theme.fg
            accessibilityLabel = text
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let b = contentView.bounds
            label.frame = b.insetBy(dx: 4, dy: 0)
            right.frame = CGRect(x: b.width - 0.5, y: 0, width: 0.5, height: b.height)
            bottom.frame = CGRect(x: 0, y: b.height - 0.5, width: b.width, height: 0.5)
        }
    }
}

extension UIImage {
    /// 1×1 纯色图，用作按钮按下底色（动态颜色在绘制时解析）
    static func pixel(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
