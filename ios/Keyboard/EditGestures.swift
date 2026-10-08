import CoreGraphics

/// 空格长按移光标：手指水平位移折算成整步，每步跨一个完整字符（emoji、组合字符不拆开）
struct CursorWalk {
    /// 每移一个字手指要走的点数
    static let stepWidth: CGFloat = 9

    /// 光标前后的文字快照，随每一步更新；到头时用宿主最新上下文补
    private var before: String
    private var after: String
    private var origin: CGFloat

    init(before: String?, after: String?, x: CGFloat) {
        self.before = before ?? ""
        self.after = after ?? ""
        origin = x
    }

    /// 手指到 x 时应走的步数（负 = 向左），已计入的位移不重复计
    mutating func steps(to x: CGFloat) -> Int {
        let n = Int((x - origin) / Self.stepWidth)
        origin += CGFloat(n) * Self.stepWidth
        return n
    }

    /// 走一步时 adjustTextPosition 的偏移（UTF-16）；快照里到头了返回 nil
    mutating func step(_ dir: Int) -> Int? {
        if dir < 0 {
            guard let c = before.popLast() else { return nil }
            after.insert(c, at: after.startIndex)
            return -c.utf16.count
        }
        guard let c = after.first else { return nil }
        after.removeFirst()
        before.append(c)
        return c.utf16.count
    }

    mutating func refill(before: String?, after: String?) {
        self.before = before ?? ""
        self.after = after ?? ""
    }
}

/// 删除键按住上滑：超过阈值进入「松手清空」，回落到解除线以下取消
struct ClearSwipe {
    static let arm: CGFloat = 40
    static let disarm: CGFloat = 28

    private let startY: CGFloat
    private(set) var armed = false
    /// 本次按压上滑过阈值：不再连删
    private(set) var swiped = false

    init(y: CGFloat) { startY = y }

    mutating func move(to y: CGFloat) {
        let up = startY - y
        if up > Self.arm { armed = true; swiped = true }
        else if up < Self.disarm { armed = false }
    }
}

/// 清空整个输入框：先把光标移到末尾，再从末尾按宿主给的上下文一段段往前删。
/// 宿主执行慢一拍：上下文为空或还没变就等，等够了或轮数到上限就停，避免死循环；删掉的文字按原顺序拼回供找回。
struct ClearPlan {
    enum Op: Equatable {
        /// 光标右移（UTF-16 偏移）
        case toEnd(Int)
        /// 回删这么多个字符
        case delete(Int)
        /// 上下文还没跟上，稍后再取
        case wait
        case done
    }

    static let maxRounds = 200
    /// 每轮最多等几次（键盘里每次约 50 毫秒）
    static let maxWaits = 20

    private var removed: [String] = []
    private var rounds = 0
    private var waits = 0
    private var last: (before: String, after: String)?

    var text: String { removed.reversed().joined() }

    mutating func next(before: String?, after: String?) -> Op {
        let b = before ?? "", a = after ?? ""
        let stale = (before == nil && after == nil) || (last.map { $0.before == b && $0.after == a } ?? false)
        if stale, waits < Self.maxWaits {
            waits += 1
            return .wait
        }
        if stale && last != nil || rounds >= Self.maxRounds { return .done }
        waits = 0
        last = (b, a)
        rounds += 1
        if !a.isEmpty { return .toEnd(a.utf16.count) }
        guard !b.isEmpty else { return .done }
        removed.append(b)
        return .delete(b.count)
    }
}
