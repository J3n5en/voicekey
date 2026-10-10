import Foundation

enum T9 {
    private static let keys: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (d, letters) in zip("23456789", ["abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"]) {
            for l in letters { m[l] = d }
        }
        return m
    }()

    static func digits(_ pinyin: String) -> String { String(pinyin.compactMap { keys[$0] }) }

    /// 按拼音注释把一段数字还原成字母：整音节（含按错一个键的纠错）、末尾半截、简拼首字母；注释对不上的数字取按键的首字母
    static func spell(_ run: String, _ syllables: inout ArraySlice<String>) -> [String] {
        var out: [String] = []
        var rest = Substring(run)
        while let d = rest.first {
            if let p = syllables.first {
                let c = digits(p)
                // 纠错：等长的一段只有一位按键不同，按注释的拼音显示
                if rest.hasPrefix(c) || (rest.count >= c.count && zip(rest, c).filter { $0 != $1 }.count == 1) {
                    out.append(p); rest = rest.dropFirst(c.count); syllables.removeFirst(); continue
                }
                if c.hasPrefix(rest) {
                    out.append(String(p.prefix(rest.count))); rest = ""; syllables.removeFirst(); continue
                }
                if c.first == d {
                    out.append(String(p.prefix(1))); rest = rest.dropFirst(); syllables.removeFirst(); continue
                }
            }
            out.append(firstLetter[d].map(String.init) ?? String(d))
            rest = rest.dropFirst()
        }
        return out
    }

    /// 候选拼音对上整串输入要改几个数字键（0 为拼对，每个音节最多改一个，同纠错规则）；只覆盖输入开头的候选、
    /// 对不上的为 nil。音节可以整个对上、只打声母（简拼）或残缺音节 ko（kou/kong）、在输入末尾只打了开头（补全）；
    /// `'` 跳过，已选拼音的字母须一致
    static func typos(_ comment: String, _ input: ArraySlice<Character>) -> Int? {
        typos(comment.split(separator: " ").map(String.init)[...], input)
    }

    private static func typos(_ syllables: ArraySlice<String>, _ input: ArraySlice<Character>) -> Int? {
        let input = input.drop { $0 == "'" }
        guard !input.isEmpty else { return 0 }
        guard let s = syllables.first else { return nil }
        /// 拼音开头 n 个字母对上输入（输入先结束算补全），返回改了几个数字与剩余输入
        func match(_ n: Int, _ allowed: Int) -> (used: Int, rest: ArraySlice<Character>)? {
            var used = 0, k = input.startIndex
            for l in s.prefix(n) {
                guard k < input.endIndex, input[k] != "'" else { break }
                if input[k] != l, input[k] != keys[l] {
                    if input[k].isLetter { return nil }
                    used += 1
                }
                k += 1
            }
            return used <= allowed ? (used, input[k...]) : nil
        }
        let initial = ["zh", "ch", "sh"].contains(String(s.prefix(2)))
            || "dtngkhrzcs".contains(s.prefix(1)) && ["ou", "ong"].contains(s.dropFirst()) ? [1, 2] : [1]
        var best: Int?
        for (n, allowed) in [(s.count, 1)] + initial.map({ ($0, 0) }) where n <= s.count {
            guard let m = match(n, allowed), let r = typos(syllables.dropFirst(), m.rest) else { continue }
            best = min(best ?? .max, m.used + r)
        }
        return best
    }

    private static let firstLetter: [Character: Character] = Dictionary(keys.map { ($0.value, $0.key) }) { min($0, $1) }

    /// 8105 字表全部音节，按字频降序（build-data.sh 生成）
    private static let syllables: [(pinyin: String, digits: String)] = {
        let url = Bundle.module.url(forResource: "syllables", withExtension: "txt", subdirectory: "RimeData")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return text.split(separator: "\n").map { (String($0), digits(String($0))) }
    }()

    /// 数字串开头能拼出的音节，长的在前、同长按字频；末尾补首字母
    static func options(_ run: String) -> [String] {
        guard let first = run.first else { return [] }
        let full = syllables.enumerated()
            .filter { run.hasPrefix($0.element.digits) }
            .sorted { ($0.element.digits.count, -$0.offset) > ($1.element.digits.count, -$1.offset) }
            .map(\.element.pinyin)
        let initials = keys.filter { $0.value == first }.map { String($0.key) }.sorted()
        return full + initials.filter { !full.contains($0) }
    }
}

/// 九宫格输入串的组成：数字、已选拼音（字母加 `'`）、手动分词
enum T9Token: Equatable {
    case digits(String)
    case pick(String)
    case separator

    static func parse(_ input: String) -> [T9Token] {
        var tokens: [T9Token] = []
        var chars = Array(input)[...]
        while let c = chars.first {
            if c == "'" {
                tokens.append(.separator)
                chars = chars.dropFirst()
            } else if c.isNumber {
                let run = chars.prefix { $0.isNumber }
                tokens.append(.digits(String(run)))
                chars = chars.dropFirst(run.count)
            } else {
                let run = chars.prefix { $0.isLetter }
                tokens.append(.pick(String(run)))
                chars = chars.dropFirst(run.count)
                if chars.first == "'" { chars = chars.dropFirst() }
            }
        }
        return tokens
    }

    static func join(_ tokens: [T9Token]) -> String {
        tokens.map {
            switch $0 {
            case .digits(let d): return d
            case .pick(let p): return p + "'"
            case .separator: return "'"
            }
        }.joined()
    }
}
