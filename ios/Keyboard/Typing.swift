import os
import Pinyin
import UIKit

/// 键盘一出现就在后台加载引擎、预热当前方案，避开首键约 65ms 的加载；之后只在主线程使用
enum PinyinLoader {
    private static let queue = DispatchQueue(label: "do.j3.voicekey.pinyin", qos: .userInitiated)
    private static var engine: PinyinEngine?
    private static var sessions: [PinyinLayout: PinyinSession] = [:]
    /// 本进程加载引擎的耗时（毫秒），未加载为 nil
    private(set) static var loadMs: Double?

    static func warm(_ layout: PinyinLayout) {
        queue.async { _ = make(layout) }
    }

    /// 主线程取会话；后台还没加载完就等它
    static func session(_ layout: PinyinLayout) -> PinyinSession? {
        queue.sync { make(layout) }
    }

    private static func make(_ layout: PinyinLayout) -> PinyinSession? {
        if let s = sessions[layout] { return s }
        let t0 = CACurrentMediaTime()
        if engine == nil {
            do {
                engine = try PinyinEngine.start(userDirectory: PinyinEngine.defaultUserDirectory)
            } catch {
                Bus.log("pinyin engine failed: \(error)")
                return nil
            }
        }
        guard let engine else { return nil }
        let s = PinyinSession(engine: engine, layout: layout)
        s.type(layout == .t9 ? "6" : "n")
        s.clear()
        sessions[layout] = s
        loadMs = (loadMs ?? 0) + (CACurrentMediaTime() - t0) * 1000
        return s
    }
}

/// 打字面板的组字：拼音会话加九宫格 1 键的符号轮换。各操作返回要上屏的文字
final class Composer {
    /// 九宫格 1 键空闲时轮换的符号，取雾凇 t9 的 1 键序列（待定，可换）
    static let oneKeySymbols = ["@", ".", "/", ":", "_", "-", "#", "1"]

    var layout: PinyinLayout = .qwerty {
        willSet {
            guard newValue != layout else { return }
            clear()
            sessionLoaded = false
        }
    }
    /// 1 键符号轮换到第几个，nil 为未在轮换
    private(set) var turn: Int?

    var session: PinyinSession? { PinyinLoader.session(layout) }
    private var live: PinyinSession? { sessionLoaded ? session : nil }
    private var sessionLoaded = false

    var isComposing: Bool { turn != nil || live?.isComposing == true }

    /// 候选栏首页（轮换时为转过的符号序列）
    var candidates: [String] {
        if let turn { return Self.rotated(turn) }
        return live?.candidates.map(\.text) ?? []
    }

    /// 跨页读候选，展开候选用
    func candidates(from start: Int, limit: Int) -> [String] {
        if let turn { return Array(Self.rotated(turn).dropFirst(start).prefix(limit)) }
        return live?.candidates(from: start, limit: limit).map(\.text) ?? []
    }

    /// 预编辑：已选定的字、九宫格已选拼音、其余拼音
    var preedit: (confirmed: String, picked: [String], guess: [String]) {
        if let turn { return ("", [], [Self.oneKeySymbols[turn]]) }
        guard let s = live, s.isComposing else { return ("", [], []) }
        return (s.confirmed, s.preedit.picked, s.preedit.guess)
    }

    var pinyinOptions: [String] { turn == nil ? live?.pinyinOptions ?? [] : [] }

    static func rotated(_ i: Int) -> [String] {
        Array(oneKeySymbols[i...] + oneKeySymbols[..<i])
    }

    private func use() -> PinyinSession? {
        sessionLoaded = true
        return session
    }

    /// 拼音按键：全拼 a–z 与 `'`，九宫格 2–9。符号轮换中先上屏当前符号
    func type(_ key: Character) -> String {
        let out = turn != nil ? confirmAll() : ""
        use()?.type(key)
        return out
    }

    /// 九宫格 1 键：组字中分词，空闲时开始或继续轮换符号
    func one() {
        if let t = turn {
            turn = (t + 1) % Self.oneKeySymbols.count
        } else if live?.isComposing == true {
            live?.type("'")
        } else {
            turn = 0
        }
    }

    /// 组字中删一键（九宫格依次退回数字、已选拼音、已选的词）；没在组字返回 false
    func deleteBackward() -> Bool {
        if turn != nil {
            turn = nil
            return true
        }
        return live?.deleteBackward() ?? false
    }

    /// 选候选（跨页序号），整段选完返回上屏文字
    func select(_ index: Int) -> String? {
        if let t = turn {
            let all = Self.rotated(t)
            guard index < all.count else { return nil }
            turn = nil
            return all[index]
        }
        return live?.select(absolute: index)
    }

    func pickPinyin(_ p: String) { live?.pickPinyin(p) }

    /// 连续选首选直到组字结束（标点、0 之前用）；没有候选的部分原样上屏字母
    func confirmAll() -> String {
        if turn != nil { return select(0) ?? "" }
        guard let s = live, s.isComposing else { return "" }
        for _ in 0..<40 where s.isComposing && !s.candidates.isEmpty {
            if let t = s.select(0) { return t }
        }
        return s.isComposing ? s.commitRaw() : ""
    }

    /// 不选词，上屏已选的字加拼音字母
    func commitRaw() -> String {
        if let t = turn {
            turn = nil
            return Self.oneKeySymbols[t]
        }
        guard let s = live, s.isComposing else { return "" }
        return s.commitRaw()
    }

    func clear() {
        turn = nil
        if live?.isComposing == true { live?.clear() }
    }
}

/// 按键耗时与内存；测试打开 metrics 时显示在键盘上供 UITest 读取
enum TypingStats {
    private static var total: [Double] = []
    private static var engine: [Double] = []
    private(set) static var first: (engine: Double, total: Double)?
    private static var t0 = 0.0
    private static var t1 = 0.0

    static func begin() { t0 = CACurrentMediaTime(); t1 = t0 }
    /// 引擎部分结束
    static func engineDone() { t1 = CACurrentMediaTime() }
    /// 界面已刷新并完成布局
    static func end() {
        let now = CACurrentMediaTime()
        let e = (max(t1, t0) - t0) * 1000, t = (now - t0) * 1000
        if first == nil { first = (e, t) }
        engine.append(e)
        total.append(t)
    }

    static func reset() {
        total = []
        engine = []
    }

    static var summary: String {
        func q(_ a: [Double], _ p: Double) -> Double {
            let s = a.sorted()
            return s.isEmpty ? -1 : s[min(s.count - 1, Int(Double(s.count) * p))]
        }
        return String(format: "keys=%d load=%.1f first=%.1f/%.1f p50=%.1f p95=%.1f max=%.1f eng50=%.2f eng95=%.2f mem=%.1f peak=%.1f avail=%.0f",
                      total.count, PinyinLoader.loadMs ?? -1, first?.engine ?? -1, first?.total ?? -1,
                      q(total, 0.5), q(total, 0.95), total.max() ?? -1, q(engine, 0.5), q(engine, 0.95),
                      Bus.footprintMB(), peakMB(), Double(os_proc_available_memory()) / 1_048_576)
    }

    /// 进程生命周期内 phys_footprint 峰值（jetsam 按此判定）
    static func peakMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak) / 1_048_576 : -1
    }
}
