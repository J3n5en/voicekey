import Foundation

/// 进程间传输：Darwin 通知只做信号，内容走 App Group 文件（协议见 ios/PROTOCOL.md）
enum Bus {
    static let defaultGroup = "group.do.j3.voicekey"

    /// 实际使用的 App Group。自签/重签工具常把组名改写（如加队伍 ID 后缀），
    /// 因此先试默认组名，打不开再从包内描述文件里找能打开的组；App 与键盘按同一规则选，结果一致。
    static let group: String = {
        resolveGroup(canOpen: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }) {
            var bundles = [Bundle.main.bundleURL]
            if Bundle.main.bundleURL.pathExtension == "appex" {   // 扩展再参考宿主 App 的描述文件
                bundles.append(Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent())
            }
            return bundles.flatMap(provisionedGroups)
        }
    }()

    /// 默认组能打开就用；否则候选去重后按（以默认组开头 > 含 voicekey > 字典序）取第一个能打开的，都不行回到默认组
    static func resolveGroup(canOpen: (String) -> Bool, candidates: () -> [String]) -> String {
        if canOpen(defaultGroup) { return defaultGroup }
        var seen = Set<String>()
        let unique = candidates().filter { seen.insert($0).inserted }
        func rank(_ g: String) -> Int {
            g.hasPrefix(defaultGroup) ? 0 : g.lowercased().contains("voicekey") ? 1 : 2
        }
        let sorted = unique.sorted { (rank($0), $0) < (rank($1), $1) }
        return sorted.first(where: canOpen) ?? defaultGroup
    }

    /// 包内 embedded.mobileprovision 声明的 App Group
    static func provisionedGroups(in bundleURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("embedded.mobileprovision")),
              let s = String(data: data, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>"), a.lowerBound < b.lowerBound,
              let xml = String(s[a.lowerBound..<b.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any]
        else { return [] }
        return ent["com.apple.security.application-groups"] as? [String] ?? []
    }

    /// 协议文件目录
    static let root: URL? = {
        guard let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        let u = c.appendingPathComponent("Library/Application Support/VoiceKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// 日志放 Library/Caches 下，devicectl 才能拉取
    static let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
        .appendingPathComponent("Library/Caches", isDirectory: true)

    private static var handlers: [String: () -> Void] = [:]
    private static let center = CFNotificationCenterGetDarwinNotifyCenter()

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    /// 主线程调用；回调在主线程
    static func observe(_ name: String, _ block: @escaping () -> Void) {
        handlers[name] = block
        CFNotificationCenterAddObserver(center, nil, { _, _, n, _, _ in
            guard let n = n?.rawValue as String? else { return }
            DispatchQueue.main.async { Bus.handlers[n]?() }
        }, name as CFString, nil, .deliverImmediately)
    }

    static func read<T: Decodable>(_ type: T.Type, _ file: String) -> T? {
        guard let u = root?.appendingPathComponent(file), let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    static func write<T: Encodable>(_ value: T, _ file: String) {
        guard let u = root?.appendingPathComponent(file), let d = try? JSONEncoder().encode(value) else { return }
        do { try d.write(to: u, options: .atomic) } catch { log("write \(file) failed: \(error)") }
    }

    static func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) [\(Bundle.main.bundleURL.pathExtension)] \(s)\n"
        print(line, terminator: "")
        guard let url = dir?.appendingPathComponent("log.txt"), let d = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(d)
            try? h.close()
        } else {
            do { try d.write(to: url) } catch { print("log write failed: \(error)") }
        }
    }

    /// 与 Xcode 内存仪表、jetsam 判定一致的 phys_footprint
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
