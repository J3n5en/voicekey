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

    /// 按拼音注释把一段数字还原成字母：整音节、末尾半截、简拼首字母；注释对不上的数字取按键的首字母
    static func spell(_ run: String, _ syllables: inout ArraySlice<String>) -> [String] {
        var out: [String] = []
        var rest = Substring(run)
        while let d = rest.first {
            if let p = syllables.first {
                let c = digits(p)
                if rest.hasPrefix(c) {
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
