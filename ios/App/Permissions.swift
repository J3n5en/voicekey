import AVFoundation
import CoreTelephony
import UIKit

/// 键盘、完全访问、麦克风三项权限，外加国行机的无线数据授权
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var keyboard = false
    @Published private(set) var fullAccess = false
    @Published private(set) var mic = AVAudioApplication.shared.recordPermission
    @Published private(set) var cellularRestricted = false
    private let cellular = CTCellularData()

    private init() {
        cellular.cellularDataRestrictionDidUpdateNotifier = { [weak self] s in
            DispatchQueue.main.async { self?.cellularRestricted = s == .restricted }
        }
        Bus.observe(VK.Note.keyboard) { [weak self] in self?.refresh() }
        refresh()
    }

    var micGranted: Bool { mic == .granted }
    var allSet: Bool { keyboard && fullAccess && micGranted }

    func refresh() {
        // 已启用的键盘列表在全局偏好里；完全访问由键盘出现时写回 App Group
        keyboard = (UserDefaults.standard.array(forKey: "AppleKeyboards") as? [String])?.contains(VK.keyboardBundleID) ?? false
        fullAccess = keyboard && (Bus.read(KeyboardInfo.self, VK.File.keyboard)?.fullAccess ?? false)
        mic = AVAudioApplication.shared.recordPermission
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
