import Foundation
import RimeFFI

public enum PinyinError: Error {
    case missingData
    case versionMismatch(engine: String, data: String)
}

/// 进程内唯一的 Rime 实例。词库只读包内预编译产物，选词学习写在 `userDirectory`。
public final class PinyinEngine {
    public static private(set) var shared: PinyinEngine?
    /// 键盘自己容器里的学习目录，不依赖 App Group 与完全访问
    public static var defaultUserDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rime")
    }

    let api = rime_get_api().pointee
    public let userDirectory: URL
    public let version: String
    private var traits = RimeTraits()
    private var generation = 0

    /// 首次调用初始化，之后返回同一实例（`userDirectory` 不同则切换到新目录）
    public static func start(userDirectory: URL) throws -> PinyinEngine {
        if let e = shared {
            if e.userDirectory != userDirectory { e.finalize(); shared = nil } else { return e }
        }
        let e = try PinyinEngine(userDirectory: userDirectory)
        shared = e
        return e
    }

    private init(userDirectory: URL) throws {
        guard let data = Bundle.module.url(forResource: "RimeData", withExtension: nil) else { throw PinyinError.missingData }
        version = api.get_version().map { String(cString: $0) } ?? ""
        let stamp = (try? String(contentsOf: data.appendingPathComponent("VERSION"), encoding: .utf8)) ?? ""
        guard stamp.hasPrefix("librime \(version) ") else { throw PinyinError.versionMismatch(engine: version, data: stamp) }
        self.userDirectory = userDirectory
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let c = { (s: String) in UnsafePointer(strdup(s)) }
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
        traits.shared_data_dir = c(data.path)
        traits.prebuilt_data_dir = c(data.appendingPathComponent("build").path)
        traits.user_data_dir = c(userDirectory.path)
        traits.staging_dir = c(userDirectory.appendingPathComponent("build").path)
        traits.distribution_name = c("VoiceKey")
        traits.distribution_code_name = c("voicekey")
        traits.distribution_version = c("1")
        traits.app_name = c("rime.voicekey")
        traits.min_log_level = 3
        Self.setupOnce(api, &traits)
        api.initialize(&traits)
    }

    private static var didSetup = false
    private static func setupOnce(_ api: RimeApi, _ traits: inout RimeTraits) {
        guard !didSetup else { return }
        didSetup = true
        api.setup(&traits)
    }

    private func finalize() {
        api.finalize()
        generation += 1
    }

    /// 清除选词学习：关闭引擎、删除用户词典后重新初始化，已有会话下次操作时自动重建
    public func clearLearning() {
        finalize()
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.contains(".userdb") {
            try? fm.removeItem(at: f)
        }
        api.initialize(&traits)
    }

    /// 返回仍然有效的 Rime 会话；引擎重新初始化过则新建
    func session(_ id: inout RimeSessionId, generation g: inout Int, schema: String) -> RimeSessionId {
        if g != generation || id == 0 || api.find_session(id) == 0 {
            id = api.create_session()
            _ = api.select_schema(id, schema)
            g = generation
        }
        return id
    }
}
