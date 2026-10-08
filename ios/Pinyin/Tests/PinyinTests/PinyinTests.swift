import XCTest
@testable import Pinyin

final class PinyinTests: XCTestCase {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PinyinTests-\(UUID().uuidString)")
    var engine: PinyinEngine!

    override func setUpWithError() throws {
        engine = try PinyinEngine.start(userDirectory: Self.dir)
        engine.clearLearning()
    }

    private func session(_ layout: PinyinLayout, _ keys: String = "") -> PinyinSession {
        let s = PinyinSession(engine: engine, layout: layout)
        keys.forEach(s.type)
        return s
    }

    private func index(of text: String, in s: PinyinSession, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try XCTUnwrap(s.candidates.firstIndex { $0.text == text }, "\(text) 不在 \(s.candidates.map(\.text))", file: file, line: line)
    }

    func testDataBoundToEngineVersion() {
        XCTAssertEqual(engine.version, "1.17.0")
    }

    // MARK: 全拼

    func testQwertyTypeAndCommit() {
        let s = session(.qwerty, "nihao")
        XCTAssertTrue(s.isComposing)
        XCTAssertEqual(s.input, "nihao")
        XCTAssertEqual(s.pending, "ni hao")
        XCTAssertEqual(s.candidates.first?.text, "你好")
        XCTAssertEqual(s.select(0), "你好")
        XCTAssertFalse(s.isComposing)
        XCTAssertTrue(s.candidates.isEmpty)
    }

    func testQwertyIgnoresOtherKeys() {
        let s = session(.qwerty, "'2N")
        XCTAssertFalse(s.isComposing)
        "xi'an".forEach(s.type)
        XCTAssertEqual(s.input, "xi'an")
        XCTAssertEqual(s.candidates.first?.text, "西安")
    }

    func testQwertyPartialSelect() throws {
        let s = session(.qwerty, "nihao")
        XCTAssertNil(s.select(try index(of: "你", in: s)))
        XCTAssertEqual(s.confirmed, "你")
        XCTAssertEqual(s.pending, "hao")
        XCTAssertEqual(s.composition, "你hao")
        XCTAssertEqual(s.candidates.first?.text, "好")
        XCTAssertEqual(s.select(0), "你好")
    }

    func testQwertyDelete() throws {
        let s = session(.qwerty, "nihao")
        XCTAssertNil(s.select(try index(of: "你", in: s)))
        s.deleteBackward()
        XCTAssertEqual(s.input, "niha")
        XCTAssertEqual(s.confirmed, "你", "删未选定部分不影响已选的字")
        s.deleteBackward(); s.deleteBackward()
        XCTAssertEqual(s.input, "ni")
        s.deleteBackward(); s.deleteBackward()
        XCTAssertFalse(s.isComposing)
        XCTAssertEqual(s.composition, "")
        XCTAssertFalse(s.deleteBackward())
    }

    func testQwertyCommitRaw() throws {
        let s = session(.qwerty, "nihao")
        XCTAssertEqual(s.commitRaw(), "nihao")
        XCTAssertFalse(s.isComposing)
        "nihao".forEach(s.type)
        XCTAssertNil(s.select(try index(of: "你", in: s)))
        XCTAssertEqual(s.commitRaw(), "你hao")
        XCTAssertFalse(s.isComposing)
    }

    func testQwertyPaging() {
        let s = session(.qwerty, "shi")
        XCTAssertEqual(s.candidates.count, 20)
        XCTAssertFalse(s.previousPage())
        let first = s.candidates
        XCTAssertTrue(s.nextPage())
        XCTAssertEqual(s.pageIndex, 1)
        XCTAssertNotEqual(s.candidates, first)
        let second = s.candidates[2].text
        XCTAssertTrue(s.previousPage())
        XCTAssertEqual(s.candidates, first)
        s.nextPage()
        XCTAssertEqual(s.select(2), second, "选第二页的词")
    }

    func testQwertyLastPage() {
        let s = session(.qwerty, "zhongguorenmin")
        var pages = 0
        while s.nextPage() { pages += 1 }
        XCTAssertTrue(s.isLastPage)
        XCTAssertFalse(s.nextPage())
        XCTAssertEqual(s.pageIndex, pages)
    }

    func testQwertyLearningAndClear() throws {
        let s = session(.qwerty, "shi")
        let original = try XCTUnwrap(s.candidates.first?.text)
        let word = s.candidates[5].text
        for _ in 0..<2 {
            s.clear(); "shi".forEach(s.type)
            XCTAssertEqual(s.select(try index(of: word, in: s)), word)
        }
        "shi".forEach(s.type)
        XCTAssertEqual(s.candidates.first?.text, word, "选两次后排到首位")
        let files = try FileManager.default.contentsOfDirectory(atPath: engine.userDirectory.path)
        XCTAssertTrue(files.contains("vk.userdb"), "学习存在键盘自己的目录：\(files)")

        engine.clearLearning()
        s.clear(); "shi".forEach(s.type)
        XCTAssertEqual(s.candidates.first?.text, original, "清除学习后恢复")
    }

    // MARK: 九宫格

    func testT9TypeAndCommit() {
        let s = session(.t9, "64426")
        XCTAssertEqual(s.candidates.first?.text, "你好")
        XCTAssertEqual(s.candidates.first?.comment, "ni hao")
        XCTAssertEqual(s.select(0), "你好")
        XCTAssertFalse(s.isComposing)
    }

    func testT9IgnoresOtherKeys() {
        let s = session(.t9, "'01a")
        XCTAssertFalse(s.isComposing)
    }

    func testT9PinyinOptions() {
        let s = session(.t9, "64426")
        let o = s.pinyinOptions
        XCTAssertEqual(Set(o.prefix(2)), ["ni", "mi"], "\(o)")
        XCTAssertEqual(Array(o.suffix(3)), ["o", "m", "n"], "单字母音节在前、补的首字母在后：\(o)")
        XCTAssertEqual(o.count, Set(o).count, "无重复")
    }

    func testT9PickNarrowsCandidates() {
        let s = session(.t9, "64426")
        s.pickPinyin("mi")
        XCTAssertEqual(s.input, "mi'426")
        XCTAssertFalse(s.candidates.isEmpty)
        for c in s.candidates { XCTAssertTrue(c.comment.hasPrefix("mi"), "\(c)") }
        XCTAssertTrue(s.pinyinOptions.contains("hao"))
        XCTAssertTrue(s.pinyinOptions.contains("gan"))
        s.pickPinyin("gan")
        XCTAssertEqual(s.input, "mi'gan'")
        XCTAssertTrue(s.pinyinOptions.isEmpty)
        for c in s.candidates { XCTAssertTrue(c.comment.hasPrefix("mi"), "\(c)") }
        XCTAssertTrue(s.candidates.contains { $0.comment == "mi gan" }, "\(s.candidates)")
        s.pickPinyin("zzz")
        XCTAssertEqual(s.input, "mi'gan'", "不在左侧列表里的拼音不接受")
    }

    func testT9DeleteRevertsPick() {
        let s = session(.t9, "64426")
        s.pickPinyin("ni")
        s.pickPinyin("hao")
        XCTAssertEqual(s.input, "ni'hao'")
        s.deleteBackward()
        XCTAssertEqual(s.input, "ni'42", "删最后一键，已选拼音退回数字")
        XCTAssertTrue(s.pinyinOptions.contains("ha"))
        s.deleteBackward(); s.deleteBackward()
        XCTAssertEqual(s.input, "ni'")
        s.deleteBackward()
        XCTAssertEqual(s.input, "6")
        s.deleteBackward()
        XCTAssertFalse(s.isComposing)
        XCTAssertFalse(s.deleteBackward())
    }

    func testT9Separator() {
        let s = session(.t9, "6''4")
        XCTAssertEqual(s.input, "6'4")
        XCTAssertEqual(s.pinyinOptions.first.map { T9.digits($0) }, "6")
        s.deleteBackward()
        XCTAssertEqual(s.input, "6'")
    }

    func testT9PartialSelectThenPick() throws {
        let s = session(.t9, "64426")
        XCTAssertNil(s.select(try index(of: "你", in: s)))
        XCTAssertEqual(s.confirmed, "你")
        XCTAssertTrue(s.pinyinOptions.contains("hao"), "左侧拼音跟着未选定部分走：\(s.pinyinOptions)")
        XCTAssertFalse(s.pinyinOptions.contains("ni"))
        s.pickPinyin("hao")
        XCTAssertEqual(s.input, "64hao'")
        XCTAssertEqual(s.confirmed, "你", "选拼音不影响已选的字")
        XCTAssertEqual(s.candidates.first?.text, "好")
        XCTAssertEqual(s.select(0), "你好")
    }

    func testDeleteReopensSelectedWords() throws {
        let s = session(.t9, "6442694664486736")
        XCTAssertNil(s.select(try index(of: "你好", in: s)))
        XCTAssertNil(s.select(try index(of: "中国", in: s)))
        "736".forEach { _ in s.deleteBackward() }
        XCTAssertEqual(s.confirmed, "你好", "删光数字后先退回最后选的词")
        XCTAssertEqual(s.candidates.first?.text, "中国")
        "94664486".forEach { _ in s.deleteBackward() }
        XCTAssertEqual(s.confirmed, "")
        XCTAssertEqual(s.candidates.first?.text, "你好")
        let q = session(.qwerty, "nihao")
        XCTAssertNil(q.select(try index(of: "你", in: q)))
        "hao".forEach { _ in q.deleteBackward() }
        XCTAssertEqual(q.confirmed, "")
        XCTAssertEqual(q.candidates.first?.text, "你", "不会停在只剩已选字、没有候选的状态")
    }

    func testT9CommitRaw() {
        let s = session(.t9, "64426")
        s.pickPinyin("ni")
        XCTAssertEqual(s.preedit.picked, ["ni"])
        XCTAssertEqual(s.preedit.guess, ["hao"], "数字按首选的拼音注释还原")
        XCTAssertEqual(s.commitRaw(), "nihao", "确认上屏预览里的字母")
    }

    func testPreedit() {
        let q = session(.qwerty, "xi'anh")
        XCTAssertEqual(q.preedit.guess, ["xi", "an", "h"])
        let t = session(.t9, "94664")
        XCTAssertEqual(T9.digits(t.preedit.guess.joined()), "94664", "\(t.preedit)")
        var syl = ["zhong", "guo"][...]
        XCTAssertEqual(T9.spell("94664486", &syl), ["zhong", "guo"])
        var miss = ["zhong"][...]
        XCTAssertEqual(T9.spell("9448", &miss), ["z", "g", "g", "t"], "注释对不上或用完后取按键首字母")
        var abbr = ["nan", "hao"][...]
        XCTAssertEqual(T9.spell("64", &abbr), ["n", "h"])
        var part = ["zhong"][...]
        XCTAssertEqual(T9.spell("946", &part), ["zho"])
    }

    func testCandidatesAcrossPages() {
        let s = session(.qwerty, "shi")
        let first = s.candidates
        let all = s.candidates(from: 0, limit: 50)
        XCTAssertEqual(all.count, 50)
        XCTAssertEqual(Array(all.prefix(20)), first)
        XCTAssertEqual(s.pageIndex, 0, "读取不翻页")
        XCTAssertEqual(s.candidates(from: 30, limit: 5), Array(all[30..<35]))
        XCTAssertEqual(s.select(absolute: 33), all[33].text)
        XCTAssertFalse(s.isComposing)
    }

    func testT9PagingAndLearning() throws {
        let s = session(.t9, "744")
        XCTAssertTrue(s.nextPage())
        XCTAssertEqual(s.pageIndex, 1)
        XCTAssertTrue(s.previousPage())
        let word = s.candidates[6].text
        for _ in 0..<2 {
            s.clear(); "744".forEach(s.type)
            XCTAssertEqual(s.select(try index(of: word, in: s)), word)
        }
        "744".forEach(s.type)
        XCTAssertEqual(s.candidates.first?.text, word)
        engine.clearLearning()
        s.clear(); "744".forEach(s.type)
        XCTAssertNotEqual(s.candidates.first?.text, word)
    }

    // MARK: 纯函数

    func testKeyLatency() {
        let clock = ContinuousClock()
        let pinyin = "zhonghuarenmingongheguo"
        for (layout, keys) in [(PinyinLayout.qwerty, pinyin), (.t9, T9.digits(pinyin))] {
            let s = session(layout)
            let ms = keys.map { k in clock.measure { s.type(k) } / .milliseconds(1) }
            print("\(layout) 每键毫秒 \(ms.map { String(format: "%.1f", $0) })，中位 \(String(format: "%.1f", ms.sorted()[ms.count / 2]))，首选 \(s.candidates.first?.text ?? "")")
            XCTAssertLessThan(ms.max()!, 100)
        }
    }

    func testT9Tokens() {
        let input = "ni'64'4hao'"
        let tokens = T9Token.parse(input)
        XCTAssertEqual(tokens, [.pick("ni"), .digits("64"), .separator, .digits("4"), .pick("hao")])
        XCTAssertEqual(T9Token.join(tokens), input)
        XCTAssertEqual(T9.digits("zhuang"), "948264")
    }

    func testOpenStart() {
        XCTAssertEqual(PinyinSession.openStart(input: "nihao", pending: "hao"), 2)
        XCTAssertEqual(PinyinSession.openStart(input: "ni'64", pending: "64"), 3)
        XCTAssertEqual(PinyinSession.openStart(input: "nihao", pending: "ni hao"), 0)
    }
}
