import Foundation

/// 键盘侧听写规则（沿用桌面）：只看 state.json 里属于本键盘的那句话
enum Dictation {
    enum Mode: Equatable {
        case idle
        case recording
        case finalizing
        /// 多渠道全部定稿或失败，候选框开着等选
        case picking
        /// 单渠道识别失败，录音保留可重试
        case failed
    }

    enum Tap: Equatable {
        /// ping 主 App，会话在就 start，否则拉起主 App
        case begin
        case stop(Int)
        /// continue：接着说 / 继续听，拼在同一句后
        case resume(Int)
    }

    enum Pick: Equatable {
        case commit(String)
        /// 先结束录音，等该行定稿后上屏
        case stopAndWait(String)
        /// 等该行定稿后上屏
        case wait(String)
        case unavailable(String)
    }

    enum Pending: Equatable {
        case keep
        case commit(String)
        /// 所选渠道没有结果；fallback 为改选的渠道
        case failed(fallback: String?)
    }

    static func mode(_ u: LiveState.Utterance?) -> Mode {
        guard let u else { return .idle }
        switch u.phase {
        case .recording: return .recording
        case .finalizing: return .finalizing
        case .done:
            if u.rows.count > 1 { return .picking }
            return u.rows.first?.state == .final ? .idle : .failed
        case .failed: return .idle
        }
    }

    /// 录音中点＝结束；识别中点＝接着说；候选框开着点＝继续听（候选框只能 ✕ 关）
    static func tap(_ u: LiveState.Utterance?) -> Tap {
        guard let u else { return .begin }
        switch mode(u) {
        case .recording: return .stop(u.id)
        case .finalizing, .picking: return .resume(u.id)
        case .idle, .failed: return .begin
        }
    }

    static func usable(_ r: LiveState.Row) -> Bool { r.state == .final && !r.text.isEmpty }

    /// 点候选里的某一行
    static func pick(_ ch: String, in u: LiveState.Utterance) -> Pick {
        guard let r = u.rows.first(where: { $0.channel == ch }), r.state != .error, !(r.state == .final && r.text.isEmpty) else { return .unavailable(ch) }
        if u.phase == .recording { return .stopAndWait(ch) }
        return r.state == .final ? .commit(ch) : .wait(ch)
    }

    /// 提前选的行定稿了就上屏；失败则改选第一条有结果的
    static func settle(pending ch: String, in u: LiveState.Utterance) -> Pending {
        guard u.phase != .recording, let r = u.rows.first(where: { $0.channel == ch }) else { return .keep }
        if usable(r) { return .commit(ch) }
        if r.state == .error || r.state == .final { return .failed(fallback: u.rows.first(where: usable)?.channel) }
        return .keep
    }

    /// 默认选中上次上屏的渠道；所选渠道失败时改选第一条有结果的
    static func selection(_ current: String?, lastPick: String?, rows: [LiveState.Row]) -> String? {
        let cur = current.flatMap { c in rows.first { $0.channel == c } } ?? lastPick.flatMap { c in rows.first { $0.channel == c } } ?? rows.first
        guard let cur else { return nil }
        if cur.state == .error || (cur.state == .final && cur.text.isEmpty), let ok = rows.first(where: usable) { return ok.channel }
        return cur.channel
    }
}
