import Foundation

/// 进程间传输：Darwin 通知只做信号，内容走 App Group 文件（协议见 ios/PROTOCOL.md）
enum Bus {
    static let group = "group.do.j3.voicekey"

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
