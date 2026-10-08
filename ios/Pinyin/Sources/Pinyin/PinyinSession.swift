import Foundation
import RimeFFI

public enum PinyinLayout {
    /// 26 键全拼
    case qwerty
    /// 九宫格：输入数字 2–9，`'` 分词
    case t9

    var schema: String { self == .qwerty ? "vk_pinyin" : "vk_t9" }
}

public struct PinyinCandidate: Equatable {
    public let text: String
    /// 九宫格下为候选的拼音（如 "ni hao"），全拼下一般为空
    public let comment: String
}

/// 一个输入框里的拼音组字会话，只在主线程使用
public final class PinyinSession {
    public let layout: PinyinLayout
    private let engine: PinyinEngine
    private var id: RimeSessionId = 0
    private var generation = -1

    /// Rime 原始输入串（九宫格选过的拼音以字母加 `'` 出现）
    public private(set) var input = ""
    /// 组字串里已选定的部分
    public private(set) var confirmed = ""
    /// 组字串里未选定的部分（Rime 预编辑，音节以空格隔开）
    public private(set) var pending = ""
    /// 当前页候选
    public private(set) var candidates: [PinyinCandidate] = []
    public private(set) var pageIndex = 0
    public private(set) var isLastPage = true
    /// 九宫格左侧拼音：当前第一段待定数字可拼出的拼音，长的在前、同长按字频
    public private(set) var pinyinOptions: [String] = []
    /// 未选定部分的拼音预览：`picked` 为九宫格已选的拼音，`guess` 为其余音节（九宫格按首选候选的拼音注释把数字还原成字母）
    public private(set) var preedit: (picked: [String], guess: [String]) = ([], [])
    /// 未选定部分在 `input` 中的起点
    private var openStart = 0

    public var isComposing: Bool { !input.isEmpty }
    public var composition: String { confirmed + pending }

    public init(engine: PinyinEngine, layout: PinyinLayout) {
        self.engine = engine
        self.layout = layout
    }

    private var api: RimeApi { engine.api }
    private var sid: RimeSessionId { engine.session(&id, generation: &generation, schema: layout.schema) }

    /// 按键：全拼收 a–z，九宫格收 2–9，两者都收 `'` 分词
    public func type(_ key: Character) {
        let ok: Bool
        switch layout {
        case .qwerty: ok = key.isASCII && (key.isLowercase || key == "'")
        case .t9: ok = ("2"..."9").contains(key) || key == "'"
        }
        guard ok, !(key == "'" && (input.isEmpty || input.last == "'")) else { return }
        setInput(input + String(key))
    }

    /// 删除最后一次按键；九宫格删到选过的拼音时，该拼音退回数字；未选定部分删光后退回最后选的词。没有在组字返回 false
    @discardableResult
    public func deleteBackward() -> Bool {
        guard isComposing else { return false }
        guard layout == .t9 else {
            setInput(String(input.dropLast()))
            return true
        }
        var tokens = T9Token.parse(input)
        switch tokens.removeLast() {
        case .separator: break
        case .digits(let d): if d.count > 1 { tokens.append(.digits(String(d.dropLast()))) }
        case .pick(let p):
            let d = T9.digits(p).dropLast()
            if !d.isEmpty { tokens.append(.digits(String(d))) }
        }
        setInput(T9Token.join(tokens))
        return true
    }

    /// 选当前页第 `index` 个候选；整段选完返回要上屏的文字，否则继续组字返回 nil
    public func select(_ index: Int) -> String? {
        guard index >= 0, index < candidates.count else { return nil }
        _ = api.select_candidate_on_current_page(sid, index)
        return refresh()
    }

    /// 选第 `index` 个候选（跨页的绝对序号，展开候选用）
    public func select(absolute index: Int) -> String? {
        guard isComposing, index >= 0 else { return nil }
        _ = api.select_candidate(sid, index)
        return refresh()
    }

    /// 从第 `start` 个起最多 `limit` 个候选，跨页读取、不改变当前页
    public func candidates(from start: Int, limit: Int) -> [PinyinCandidate] {
        guard isComposing, limit > 0 else { return [] }
        var it = RimeCandidateListIterator()
        guard api.candidate_list_from_index(sid, &it, Int32(start)) != 0 else { return [] }
        defer { api.candidate_list_end(&it) }
        var out: [PinyinCandidate] = []
        while out.count < limit, api.candidate_list_next(&it) != 0 {
            let c = it.candidate
            out.append(PinyinCandidate(text: String(cString: c.text), comment: c.comment.map { String(cString: $0) } ?? ""))
        }
        return out
    }

    /// 不选词直接上屏：已选定的字加未选定部分的字母（九宫格取预览里的拼音）
    public func commitRaw() -> String {
        let open = layout == .t9 ? (preedit.picked + preedit.guess).joined() : String(Array(input)[openStart...]).replacingOccurrences(of: "'", with: "")
        let text = confirmed + open
        clear()
        return text
    }

    public func clear() {
        api.clear_composition(sid)
        _ = refresh()
    }

    @discardableResult
    public func nextPage() -> Bool { changePage(backward: false) }
    @discardableResult
    public func previousPage() -> Bool { changePage(backward: true) }

    private func changePage(backward: Bool) -> Bool {
        guard isComposing, backward ? pageIndex > 0 : !isLastPage else { return false }
        _ = api.change_page(sid, backward ? 1 : 0)
        _ = refresh()
        return true
    }

    /// 九宫格选左侧拼音：把对应数字换成该拼音，候选随之收窄
    public func pickPinyin(_ pinyin: String) {
        guard layout == .t9, pinyinOptions.contains(pinyin), let run = firstDigitRun() else { return }
        let chars = Array(input)
        let end = run.lowerBound + T9.digits(pinyin).count
        let sep = end < chars.count && chars[end] == "'" ? "" : "'"
        setInput(String(chars[..<run.lowerBound]) + pinyin + sep + String(chars[end...]))
    }

    private func setInput(_ s: String) {
        if s.isEmpty { api.clear_composition(sid) } else { _ = api.set_input(sid, s) }
        _ = refresh()
        if isComposing, pending.isEmpty, !confirmed.isEmpty {
            _ = api.process_key(sid, 0xff08, 0)
            _ = refresh()
        }
    }

    /// 从 Rime 读回状态，返回本次产生的上屏文字
    private func refresh() -> String? {
        let s = sid
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        var committed: String?
        if api.get_commit(s, &commit) != 0 {
            committed = commit.text.map { String(cString: $0) }
            _ = api.free_commit(&commit)
        }
        input = api.get_input(s).map { String(cString: $0) } ?? ""
        confirmed = ""; pending = ""; candidates = []; pageIndex = 0; isLastPage = true; openStart = 0; preedit = ([], [])
        var ctx = RimeContext()
        ctx.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        if !input.isEmpty, api.get_context(s, &ctx) != 0 {
            let bytes = Array((ctx.composition.preedit.map { String(cString: $0) } ?? "").utf8)
            let sel = min(max(Int(ctx.composition.sel_start), 0), bytes.count)
            confirmed = String(decoding: bytes[..<sel], as: UTF8.self)
            pending = String(decoding: bytes[sel...], as: UTF8.self)
            let menu = ctx.menu
            candidates = (0..<Int(menu.num_candidates)).map {
                let c = menu.candidates[$0]
                return PinyinCandidate(text: String(cString: c.text), comment: c.comment.map { String(cString: $0) } ?? "")
            }
            pageIndex = Int(menu.page_no)
            isLastPage = menu.is_last_page != 0
            _ = api.free_context(&ctx)
            openStart = Self.openStart(input: input, pending: pending)
        }
        pinyinOptions = layout == .t9 ? firstDigitRun().map { T9.options(String(Array(input)[$0])) } ?? [] : []
        if !input.isEmpty { preedit = layout == .t9 ? t9Preedit() : ([], pending.split { $0 == " " || $0 == "'" }.map(String.init)) }
        return committed
    }

    private func t9Preedit() -> (picked: [String], guess: [String]) {
        var syllables = (candidates.first?.comment ?? "").split(separator: " ").map(String.init)[...]
        var picked: [String] = [], guess: [String] = []
        for t in T9Token.parse(String(Array(input)[openStart...])) {
            switch t {
            case .pick(let p):
                picked.append(p)
                if syllables.first == p { syllables.removeFirst() }
            case .digits(let d): guess += T9.spell(d, &syllables)
            case .separator: break
            }
        }
        return (picked, guess)
    }

    /// 未选定的预编辑与输入串末尾对齐：按字母数字个数从后往前数
    static func openStart(input: String, pending: String) -> Int {
        var need = pending.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.count
        let chars = Array(input)
        var i = chars.count
        while i > 0, need > 0 {
            i -= 1
            if chars[i].isLetter || chars[i].isNumber { need -= 1 }
        }
        return i
    }

    /// 未选定部分里、跳过已选拼音后的第一段数字
    private func firstDigitRun() -> Range<Int>? {
        let chars = Array(input)
        guard let start = chars[openStart...].firstIndex(where: \.isNumber) else { return nil }
        let end = chars[start...].firstIndex { !$0.isNumber } ?? chars.count
        return start..<end
    }
}
