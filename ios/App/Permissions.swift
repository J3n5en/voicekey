import AVFoundation
import CoreTelephony
import UIKit

/// 键盘、完全访问、麦克风三项权限，外加国行机的无线数据授权
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var keyboard = false
    @Published private(set) var fullAccess = false
    /// 本次运行里看到 VoiceKey 键盘出现过，可确证已添加
    @Published private(set) var keyboardSeen = false
    @Published private(set) var mic = AVAudioApplication.shared.recordPermission
    @Published private(set) var cellularRestricted = false
    private let cellular = CTCellularData()
    private var seenAt: Double?

    private init() {
        cellular.cellularDataRestrictionDidUpdateNotifier = { [weak self] s in
            DispatchQueue.main.async { self?.cellularRestricted = s == .restricted }
        }
        Bus.observe(VK.Note.keyboard) { [weak self] in self?.keyboardShown() }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    var micGranted: Bool { mic == .granted }
    var allSet: Bool { keyboard && fullAccess && micGranted }

    func refresh() {
        // 完全访问只能靠键盘出现时写回 App Group；键盘刚出现却没写新的，说明完全访问没开
        let info = Bus.read(KeyboardInfo.self, VK.File.keyboard)
        keyboard = keyboardSeen || Self.keyboardListed() ?? (info != nil)
        fullAccess = keyboard && info.map { $0.fullAccess && $0.at > (seenAt ?? 0) - 5 } ?? false
        mic = AVAudioApplication.shared.recordPermission
    }

    /// VoiceKey 键盘刚出现：开了完全访问的键盘会发通知，没开的由引导输入框看到
    func keyboardShown() {
        keyboardSeen = true
        seenAt = VK.now
        refresh()
    }

    /// 系统已启用的输入法里有没有 VoiceKey：输入法列表与全局偏好 AppleKeyboards 任一命中即算；两者都读不到返回 nil
    private static func keyboardListed() -> Bool? {
        let modes = UITextInputMode.activeInputModes.compactMap(\.vkID)
        let prefs = UserDefaults.standard.array(forKey: "AppleKeyboards") as? [String]
        if modes.isEmpty && prefs == nil { return nil }
        return modes.contains(VK.keyboardBundleID) || prefs?.contains(VK.keyboardBundleID) == true
    }

    func requestMic(_ done: ((Bool) -> Void)? = nil) {
        guard mic == .undetermined else {
            if !micGranted { Self.openSettings() }
            done?(micGranted)
            return
        }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async {
                self.refresh()
                done?(ok)
            }
        }
    }

    /// 本 App 的系统设置页，键盘、麦克风、无线数据开关都在这里
    static func openSettings() {
        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
    }

    /// 国行机首次联网才会弹「允许使用无线数据」，引导一开始就触发
    static func pokeNetwork() {
        URLSession.shared.dataTask(with: URL(string: "https://www.apple.com/library/test/success.html")!) { _, _, e in
            Bus.log("network probe \(e.map { "\($0)" } ?? "ok")")
        }.resume()
    }
}

extension UITextInputMode {
    /// 输入法标识，第三方键盘即扩展的 bundle ID
    var vkID: String? { responds(to: NSSelectorFromString("identifier")) ? value(forKey: "identifier") as? String : nil }
}
