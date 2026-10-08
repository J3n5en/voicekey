import UIKit

/// 打字按键区：26 键（字母、数字、符号页）与九宫格，按 design/ios/index.html
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
    }

    private enum Width { case unit, fixed(CGFloat), flex }

    private struct Item {
        let key: Key
        let button: KeyButton
        var width = Width.unit
        /// 与下一个键之间额外的间距
        var extra: CGFloat = 0
        /// 九宫格位置：列、行
        var cell: (Int, Int)?
    }

    var onKey: ((Key) -> Void)?
    /// 九宫格左列：组字中为拼音，空闲时为标点
    var onList: ((String, _ pinyin: Bool) -> Void)?
    /// 空格、删除、🌐 的触摸交给控制器
    var wire: ((KeyButton, Key) -> Void)?

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
    }

    required init?(coder: NSCoder) { fatalError() }

    var keys: [KeyButton] { rows.flatMap { $0.map(\.button) } }
    var sideList: UIView { list }

    func set(_ s: Spec) {
        spec = s
        guard built != s else { return }
        built = s
        rows.flatMap { $0 }.forEach { $0.button.removeFromSuperview() }
        rows = s.t9 && s.page != .sym ? t9Rows(s) : qwertyRows(s)
        listCell = s.t9 && s.page != .sym
        if listCell { addSubview(list) } else { list.removeFromSuperview() }
        rows.flatMap { $0 }.forEach { addSubview($0.button) }
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
            b = KeyButton(t, style: c == "'" ? .fn : .key)
            b.fontSize = 21
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
            b.fontSize = s.count == 1 && s.first!.isNumber ? 21 : 18
            b.accessibilityLabel = s
        case .space:
            b = KeyButton("空格", style: .key)
            b.fontSize = 14
            b.accessibilityIdentifier = "空格"
            space = b
        case .back:
            b = KeyButton(symbol: "delete.left", style: .fn)
            b.accessibilityLabel = "删除"
        case .enter:
            b = KeyButton("换行", style: .enter)
            b.fontSize = 14
            b.accessibilityIdentifier = "换行"
            enter = b
        case .globe:
            b = KeyButton(symbol: "globe", style: .fn)
            b.accessibilityLabel = "切换输入法"
        case .shift:
            b = KeyButton(symbol: spec.shift ? "shift.fill" : "shift", style: spec.shift ? .key : .fn)
            b.accessibilityLabel = "大写"
        case .lang:
            b = KeyButton(nil, style: .fn)
            let on = UIFont.systemFont(ofSize: 14), off = UIFont.systemFont(ofSize: 11)
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
            b = KeyButton(title, style: .fn)
            b.fontSize = 14
        }
        if [.space, .back, .globe].contains(key) {
            wire?(b, key)
        } else {
            b.addAction(UIAction { [weak self] _ in self?.onKey?(key) }, for: .touchUpInside)
        }
        return b
    }

    private func item(_ key: Key, _ w: Width = .unit, extra: CGFloat = 0, fn: Bool = false, size: CGFloat? = nil) -> Item {
        let b = make(key)
        if fn { b.style = .fn }
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
            let lead = zh ? item(.letter("'"), .fixed(42), extra: 5) : item(.shift, .fixed(42), extra: 5)
            r = [letters("qwertyuiop"), letters("asdfghjkl"), [lead] + letters("zxcvbnm") + [item(.back, .fixed(42))]]
            r[2][r[2].count - 2].extra = 10
        case .num, .sym:
            let num = s.page == .num
            let row1 = num ? "1234567890".map(String.init) : ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
            let row2 = num ? (zh ? ["，", "。", "？", "！", "、", "：", "；", "（", "）", "@"] : ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""])
                : ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"]
            let row3 = zh ? ["…", "—", "《", "》", "“", "”", "·"] : [".", ",", "?", "!", "'", "-", "…"]
            var third = [item(.page(num ? .sym : .num), .fixed(42), extra: 5)] + texts(row3) + [item(.back, .fixed(42))]
            third[third.count - 2].extra = 10
            r = [texts(row1), texts(row2), third]
        }
        r.append([
            item(.page(s.page == .abc ? .num : .abc), .fixed(40)),
            item(.globe, .fixed(31)),
            item(.text(zh ? "，" : ","), .fixed(27), fn: true, size: 16),
            item(.space, .flex),
            item(.text(zh ? "。" : "."), .fixed(27), fn: true, size: 16),
            item(.lang, .fixed(40)),
            item(.enter, .fixed(48)),
        ])
        return r
    }

    private static let t9Letters: [Character: String] = ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ"]

    private func t9Rows(_ s: Spec) -> [[Item]] {
        func at(_ key: Key, _ c: Int, _ r: Int, fn: Bool = false) -> Item {
            var i = item(key, fn: fn)
            i.cell = (c, r)
            return i
        }
        var grid: [Item]
        let bottom: [Item]
        if s.page == .num {
            grid = (1...9).map { n in at(.text(String(n)), (n - 1) % 3 + 1, (n - 1) / 3) }
            grid += [at(.back, 4, 0), at(.text("."), 4, 1, fn: true), at(.enter, 4, 2)]
            bottom = [item(.page(.abc), .fixed(50)), item(.globe, .fixed(31)), item(.page(.sym), .fixed(44)), item(.text("0"), .flex), item(.space, .flex)]
        } else {
            grid = [at(.one, 1, 0)] + (2...9).map { n in at(.digit(Character(String(n))), (n - 1) % 3 + 1, (n - 1) / 3) }
            // 待定点 4：0 单独一个键，放在 ⌫ 下面
            grid += [at(.back, 4, 0), at(.text("0"), 4, 1, fn: true), at(.enter, 4, 2)]
            bottom = [item(.page(.num), .fixed(50)), item(.globe, .fixed(31)), item(.space, .flex), item(.lang, .fixed(50))]
        }
        return [grid, bottom]
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        if listCell { layoutT9() } else { layoutQwerty() }
    }

    private func layoutQwerty() {
        let w = bounds.width, h = bounds.height, pad: CGFloat = 3, gap: CGFloat = 5
        let unit = floor((w - 2 * pad - 9 * gap) / 10)
        let n = CGFloat(rows.count)
        let rowH = min(42, floor((h - 4 * (n + 1)) / n))
        let vgap = (h - n * rowH) / (n + 1)
        for (i, row) in rows.enumerated() {
            let y = vgap + CGFloat(i) * (rowH + vgap)
            place(row, x0: pad, width: w - 2 * pad, y: y, h: rowH, unit: unit, gap: gap)
        }
    }

    private func layoutT9() {
        let w = bounds.width, h = bounds.height, gap: CGFloat = 6, side: CGFloat = 50
        let x0: CGFloat = 1, y0: CGFloat = 2
        let mid = (w - 2 * x0 - 2 * side - 4 * gap) / 3
        let botH = min(42, h * 0.2)
        let cellH = (h - 2 * y0 - botH - 3 * gap) / 3
        func colX(_ c: Int) -> CGFloat { c == 0 ? x0 : x0 + side + gap + CGFloat(c - 1) * (mid + gap) }
        func colW(_ c: Int) -> CGFloat { c == 0 || c == 4 ? side : mid }
        list.frame = CGRect(x: colX(0), y: y0, width: side, height: 3 * cellH + 2 * gap)
        for it in rows[0] {
            guard let (c, r) = it.cell else { continue }
            it.button.frame = CGRect(x: colX(c), y: y0 + CGFloat(r) * (cellH + gap), width: colW(c), height: cellH)
        }
        place(rows[1], x0: x0, width: w - 2 * x0, y: y0 + 3 * (cellH + gap), h: botH, unit: mid, gap: 5)
    }

    private func place(_ row: [Item], x0: CGFloat, width: CGFloat, y: CGFloat, h: CGFloat, unit: CGFloat, gap: CGFloat) {
        var fixed: CGFloat = 0, flex = 0
        for (i, it) in row.enumerated() {
            switch it.width {
            case .unit: fixed += unit
            case .fixed(let f): fixed += f
            case .flex: flex += 1
            }
            if i < row.count - 1 { fixed += gap + it.extra }
        }
        let flexW = flex > 0 ? (width - fixed) / CGFloat(flex) : 0
        var x = flex > 0 ? x0 : x0 + (width - fixed) / 2
        for it in row {
            let wd: CGFloat
            switch it.width {
            case .unit: wd = unit
            case .fixed(let f): wd = f
            case .flex: wd = flexW
            }
            it.button.frame = CGRect(x: x, y: y, width: wd, height: h)
            x += wd + gap + it.extra
        }
    }
}

/// 九宫格数字键：上方小字数字，下方字母或说明
final class DigitKey: KeyButton {
    let bottom = Theme.label(16)

    init(_ digit: String, _ letters: String) {
        super.init(nil, style: .key)
        let top = Theme.label(10, Theme.fg2)
        top.text = digit
        bottom.text = letters
        let col = UIStackView(arrangedSubviews: [top, bottom])
        col.axis = .vertical
        col.alignment = .center
        col.isUserInteractionEnabled = false
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        col.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        col.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
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
        layer.cornerRadius = 6
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
        backgroundColor = pinyin ? Theme.key : Theme.key2
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
