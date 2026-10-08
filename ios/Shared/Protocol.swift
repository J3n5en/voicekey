import Foundation

/// 主 App ⇄ 键盘协议 v1，字段与时序说明见 ios/PROTOCOL.md。时间一律为 Unix 秒（Double）
enum VK {
    static let version = 1
    static let keyboardBundleID = "do.j3.voicekey.ios.keyboard"
    /// 键盘拉起主 App 开会话；source=keyboard 时主 App 提示用户点左上角返回
    static let sessionURL = URL(string: "voicekey://session?source=keyboard")!

    enum Note {
        static let cmd = "do.j3.voicekey.cmd"
        static let state = "do.j3.voicekey.state"
        static let ping = "do.j3.voicekey.ping"
        static let config = "do.j3.voicekey.config"
        static let keyboard = "do.j3.voicekey.keyboard"
        /// 操作按钮 / 快捷指令：让正在显示的键盘开始或结束说话；键盘收到回 hotkeyAck
        static let hotkey = "do.j3.voicekey.hotkey"
        static let hotkeyAck = "do.j3.voicekey.hotkey.ack"
    }

    enum File {
        static let config = "config.json"
        static let state = "state.json"
        static let cmd = "cmd.json"
        static let history = "history.json"
        static let keyboard = "keyboard.json"
        static let typing = "typing.json"
        /// 最近一次 hotkey 的时刻（秒），键盘据此忽略迟到的旧信号
        static let hotkey = "hotkey.json"
    }

    static var now: Double { Date().timeIntervalSince1970 }
}

// MARK: - 配置（双方可写，写完发 Note.config）

struct Channel: Codable, Equatable, Identifiable {
    var id: String
    /// 识别引擎，仅内部使用，界面只显示 name
    var engine: String
    var name: String
    var on: Bool
}

struct Config: Codable, Equatable {
    var channels: [Channel]
    /// 多渠道候选；打开的渠道 ≥2 时生效
    var multi: Bool
    /// 单渠道时使用
    var defaultChannel: String
    /// 无操作自动结束会话的分钟数，0 = 不自动
    var idleMinutes: Int
    /// 多渠道候选默认选中上次上屏的渠道
    var lastPick: String?

    static let idleChoices = [5, 10, 30, 0]

    static let initial = Config(
        channels: [
            Channel(id: "a", engine: "wetype", name: "微信", on: true),
            Channel(id: "b", engine: "qwen", name: "千问", on: false),
            Channel(id: "c", engine: "iflytek", name: "讯飞", on: false),
            Channel(id: "d", engine: "baidu", name: "百度", on: false),
        ],
        multi: true, defaultChannel: "a", idleMinutes: 10, lastPick: nil)

    var enabled: [Channel] { channels.filter(\.on) }
    var isMulti: Bool { multi && enabled.count >= 2 }

    /// 按当前设置本次参与识别的渠道
    var active: [Channel] {
        if isMulti { return enabled }
        return [enabled.first { $0.id == defaultChannel } ?? enabled.first].compactMap { $0 }
    }

    /// 显式指定的渠道（须存在且已打开），为空时按当前设置
    func resolve(_ ids: [String]?) -> [Channel] {
        guard let ids, !ids.isEmpty else { return active }
        return ids.compactMap { id in enabled.first { $0.id == id } }
    }

    static func load() -> Config { Bus.read(Config.self, VK.File.config)?.migrated() ?? .initial }

    /// 旧版默认名「渠道 A/B/C/D」换成新默认名，用户改过的名字不动
    func migrated() -> Config {
        var c = self
        for i in c.channels.indices where c.channels[i].name == "渠道 \(c.channels[i].id.uppercased())" {
            c.channels[i].name = Config.renamed(c.channels[i].name)
        }
        return c
    }

    /// 旧版默认名对应的新默认名，其他名字原样返回
    static func renamed(_ name: String) -> String {
        initial.channels.first { "渠道 \($0.id.uppercased())" == name }?.name ?? name
    }

    func save() {
        Bus.write(self, VK.File.config)
        Bus.post(VK.Note.config)
    }
}

// MARK: - 打字设置（主 App 与键盘双方可写）

struct TypingPrefs: Codable, Equatable {
    /// 中文键盘用九宫格，否则 26 键全拼
    var t9 = false
    /// 测试用：键盘里显示按键耗时与内存，供 UITest 读取
    var metrics = false

    /// 键盘里切布局时默认布局跟着改（待定，用户可能改成只对本次生效）
    static let toggleSetsDefault = true
    private static let localKey = "typing"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t9 = try c.decodeIfPresent(Bool.self, forKey: .t9) ?? false
        metrics = try c.decodeIfPresent(Bool.self, forKey: .metrics) ?? false
    }

    /// 有 App Group（主 App、开了完全访问的键盘）读共享设置，否则读本进程自己的副本
    static func load() -> TypingPrefs {
        if let p = Bus.read(TypingPrefs.self, VK.File.typing) { return p }
        guard let d = UserDefaults.standard.data(forKey: localKey) else { return TypingPrefs() }
        return (try? JSONDecoder().decode(TypingPrefs.self, from: d)) ?? TypingPrefs()
    }

    func save() {
        Bus.write(self, VK.File.typing)
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.localKey)
    }
}

// MARK: - 命令（键盘写，主 App 读）

struct Command: Codable, Equatable {
    enum Op: String, Codable {
        case start, stop, `continue`, retry, close, commit, touch, endSession
    }

    var seq: Int
    var at: Double
    var op: Op
    /// stop/continue/retry/close/commit 作用的 utterance.id；不符则忽略
    var utt: Int?
    /// start：渠道 id，省略按当前配置
    var channels: [String]?
    /// start：静音多少秒后自动结束，省略或 0 = 不自动
    var silenceStop: Double?
    /// commit：上屏的渠道 id
    var channel: String?
}

struct CommandQueue: Codable {
    static let keep = 32
    var cmds: [Command] = []

    var maxSeq: Int { cmds.map(\.seq).max() ?? 0 }

    /// 键盘侧：追加一条命令并通知主 App，返回 seq（用于对上 state.ackSeq / utterance.startSeq）
    @discardableResult
    static func send(_ op: Command.Op, utt: Int? = nil, channels: [String]? = nil, silenceStop: Double? = nil, channel: String? = nil) -> Int {
        var q = Bus.read(CommandQueue.self, VK.File.cmd) ?? CommandQueue()
        let ack = Bus.read(LiveState.self, VK.File.state)?.ackSeq ?? 0
        let seq = max(q.maxSeq, ack) + 1
        q.cmds.append(Command(seq: seq, at: VK.now, op: op, utt: utt, channels: channels, silenceStop: silenceStop, channel: channel))
        q.cmds = Array(q.cmds.suffix(keep))
        Bus.write(q, VK.File.cmd)
        Bus.post(VK.Note.cmd)
        return seq
    }

    /// 主 App 侧：seq 大于 after 的命令，按 seq 升序
    func pending(after: Int) -> [Command] {
        cmds.filter { $0.seq > after }.sorted { $0.seq < $1.seq }
    }
}

// MARK: - 实时状态（主 App 写，键盘读）

struct LiveState: Codable, Equatable {
    var v = VK.version
    /// 主 App 进程标识，每次启动换新；键盘据此判断主 App 是否重启过
    var launch: String
    var updatedAt: Double
    /// 已处理的最大命令 seq
    var ackSeq: Int
    var session: Session
    var utterance: Utterance?

    struct Session: Codable, Equatable {
        var active: Bool
        var since: Double?
        /// 无操作到此时刻自动结束；nil = 不自动结束或未开启
        var expiresAt: Double?
        var idleMinutes: Int
        /// 来电、Siri、其他录音 App 占用麦克风，暂时不能说
        var interrupted: Bool
        var endReason: EndReason?
        var endedAt: Double?
    }

    enum EndReason: String, Codable {
        /// 用户在主 App 或键盘结束
        case user
        /// 无操作超时
        case idle
        /// 被打断后无法恢复（需回主 App 重开）
        case interrupted
        /// 麦克风权限被拒或被关
        case micDenied
        /// 音频引擎启动失败
        case failed
    }

    struct Utterance: Codable, Equatable {
        var id: Int
        /// 发起这句话的 start 命令 seq
        var startSeq: Int
        var phase: Phase
        var stopReason: StopReason?
        var silenceStop: Double?
        /// 输入音量 0…1，聆听中约 10Hz 刷新
        var level: Float
        var rows: [Row]
        /// phase = failed 时的原因
        var error: StartError?
        /// 失败的渠道能否用保留的录音重试
        var retryable: Bool
    }

    enum Phase: String, Codable {
        case recording, finalizing, done, failed
    }

    enum StopReason: String, Codable {
        case user, silence, interrupted
    }

    enum StartError: String, Codable {
        /// 会话未开启（键盘应拉起主 App）
        case noSession
        /// 麦克风被通话或其他 App 占用
        case micBusy
        /// 没有可用渠道
        case noChannel
    }

    struct Row: Codable, Equatable {
        var channel: String
        var name: String
        /// 这句话到目前为止的完整文字（含接着说的各段），覆盖上一次
        var text: String
        var state: RowState
        /// 面向用户的简短原因，state = error 时有
        var error: String?
        /// 从结束说话到定稿的耗时
        var ms: Int?
    }

    enum RowState: String, Codable {
        case listening, finalizing, final, error
    }

    static func load() -> LiveState? { Bus.read(LiveState.self, VK.File.state) }
}

// MARK: - 识别段聚合

/// 一个渠道里「接着说」形成的一段
struct Segment: Equatable {
    var text = ""
    var state: LiveState.RowState = .listening
    var error: String?
    var stoppedAt: Double?
    var doneAt: Double?

    static func aggregate(_ segs: [Segment]) -> (text: String, state: LiveState.RowState, error: String?, ms: Int?) {
        let text = segs.filter { $0.state != .error }.map(\.text).joined()
        let state: LiveState.RowState =
            segs.contains { $0.state == .listening } ? .listening :
            segs.contains { $0.state == .finalizing } ? .finalizing :
            segs.contains { $0.state == .error } ? .error : .final
        let error = state == .error ? segs.last { $0.state == .error }?.error : nil
        var ms: Int?
        if state == .final || state == .error, let l = segs.last, let s = l.stoppedAt, let d = l.doneAt { ms = Int(((d - s) * 1000).rounded()) }
        return (text, state, error, ms)
    }
}

// MARK: - 静音自动结束

/// 说过话之后连续安静 hold 秒即判定说完；底噪自适应
struct SilenceDetector {
    let hold: Double
    private(set) var heard = false
    private var quiet = 0.0
    private var floor: Float = 0.003

    init(hold: Double) { self.hold = hold }

    /// rms 为该块音频的均方根，duration 为块时长（秒）；返回 true 表示该结束了
    mutating func feed(rms: Float, duration: Double) -> Bool {
        floor = rms < floor ? max(rms, 0.0005) : floor + (rms - floor) * 0.002
        if rms > max(0.012, floor * 3) {
            heard = true
            quiet = 0
            return false
        }
        guard heard else { return false }
        quiet += duration
        return quiet >= hold
    }
}

// MARK: - 闲置超时

enum Idle {
    /// 会话到期时刻；seconds = 0 不自动结束，busy（正在说或定稿中）时从现在算起
    static func expiry(lastActivity: Double, seconds: Double, busy: Bool, now: Double) -> Double? {
        guard seconds > 0 else { return nil }
        return (busy ? now : lastActivity) + seconds
    }
}

// MARK: - 其他共享文件

/// 最近上屏，主 App 写；上屏失败时可在主 App 里找回
struct HistoryItem: Codable, Equatable, Identifiable {
    var id: String { "\(at)" }
    var text: String
    var channel: String
    var at: Double
}

extension HistoryItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try c.decode(String.self, forKey: .text),
                  channel: Config.renamed(try c.decode(String.self, forKey: .channel)),
                  at: try c.decode(Double.self, forKey: .at))
    }
}

/// 键盘每次出现时写入；主 App 据此判断「允许完全访问」已开（没有完全访问键盘写不了 App Group）
struct KeyboardInfo: Codable, Equatable {
    var fullAccess: Bool
    var at: Double
}
