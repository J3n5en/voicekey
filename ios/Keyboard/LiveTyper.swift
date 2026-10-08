import Foundation

/// 光标处的输入框；键盘里由 textDocumentProxy 实现
protocol TextTarget: AnyObject {
    var before: String? { get }
    var after: String? { get }
    var selected: String? { get }
    func insert(_ text: String)
    func deleteBackward()
}

/// 单渠道边说边打：只回删与上次不同的尾巴再补打。
/// 输入框里对不上（光标移动、用户改字、宿主不让删、拿不到上下文却要删、会和前面的字粘连）就永久停止，宁可不改也不误删用户的字。
final class LiveTyper {
    enum Halt: Equatable {
        /// 光标移动、选中文字，或我们打的字被改动、被清空
        case diverged
        /// 宿主不给上下文，无法确认要删的是自己打的字
        case unverifiable
        /// 新文字开头会和光标前用户的字组合成一个字符（组合符、肤色、ZWJ 等）
        case boundary
    }

    enum Outcome: Equatable {
        case synced
        /// 输入框暂时对不上（宿主同步可能慢一拍），稍后再 sync
        case waiting
        case halted(Halt)
    }

    /// 记录光标前多少个字符作锚点
    static let anchorLength = 8
    /// 连续对不上几次才判定被改动
    static let patience = 3

    private unowned let target: TextTarget
    /// 输入框里属于本句、由我们打出的文字
    private(set) var typed = ""
    /// 想要达到的文字
    private(set) var want = ""
    private(set) var halt: Halt?
    /// 首次写入时光标前的文字尾部；nil = 还没写过
    private var anchor: String?
    private var afterMark: String?
    /// 宿主给过上下文；空输入框开头时 before 常为 nil，打出字后才有
    private var contextKnown = false
    private var misses = 0

    init(_ target: TextTarget) { self.target = target }

    var synced: Bool { halt == nil && typed == want }

    @discardableResult
    func set(_ text: String) -> Outcome {
        want = text
        return sync()
    }

    @discardableResult
    func sync() -> Outcome {
        if let halt { return .halted(halt) }
        if typed == want { return .synced }
        let anchor: String
        if let a = self.anchor {
            guard consistent() else {
                misses += 1
                return misses >= Self.patience ? stop(.diverged) : .waiting
            }
            anchor = a
        } else {
            let b = target.before
            contextKnown = b != nil
            anchor = b.map { String($0.suffix(Self.anchorLength)) } ?? ""
            if !contextKnown, let f = want.unicodeScalars.first, Self.joinsPrevious(f) { return stop(.boundary) }
            self.anchor = anchor
            afterMark = target.after
        }
        misses = 0
        let a = Array(anchor), old = Array(anchor + typed), new = Array(anchor + want)
        // 锚点与本句的分界必须是字符边界，否则回删会连带删掉用户的字
        guard old.count == a.count + typed.count, new.count == a.count + want.count else { return stop(.boundary) }
        var p = a.count
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        let del = old.count - p
        if del > 0 {
            guard contextKnown else { return stop(.unverifiable) }
            for _ in 0..<del { target.deleteBackward() }
            typed = String(old[a.count..<p])
            // 删除没生效（宿主拒绝或尚未同步）就先不补打，免得把新尾巴接在旧尾巴后面
            guard consistent() else {
                misses = 1
                return .waiting
            }
        }
        if p < new.count { target.insert(String(new[p...])) }
        typed = want
        return .synced
    }

    /// 停止改写（例如键盘收起）
    func abandon() {
        if halt == nil { halt = .diverged }
    }

    private func stop(_ h: Halt) -> Outcome {
        halt = h
        return .halted(h)
    }

    /// 光标前仍以「锚点 + 已打文字」结尾、光标后没变、没有选中文字
    private func consistent() -> Bool {
        guard target.after == afterMark, (target.selected ?? "").isEmpty else { return false }
        let expected = (anchor ?? "") + typed
        // 空输入框常给 nil：只要我们这边也应为空就算对得上
        guard let b = target.before else { return !contextKnown || expected.isEmpty }
        // 宿主只给了截断的一段上下文
        let ok = b.hasSuffix(expected) || (!b.isEmpty && b.count < expected.count && expected.hasSuffix(b))
        if ok { contextKnown = true }
        return ok
    }

    /// 会与前一个字符组合成同一个字符的码位
    static func joinsPrevious(_ s: Unicode.Scalar) -> Bool {
        let p = s.properties
        if p.isGraphemeExtend || p.isEmojiModifier || p.isVariationSelector { return true }
        if [.spacingMark, .nonspacingMark, .enclosingMark].contains(p.generalCategory) { return true }
        switch s.value {
        case 0x200D, 0x1F1E6...0x1F1FF, 0x1160...0x11FF, 0xD7B0...0xD7FF: return true
        default: return false
        }
    }
}
