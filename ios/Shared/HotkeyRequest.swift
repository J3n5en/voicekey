import Foundation

struct HotkeyRequest: Codable {
    var id = UUID().uuidString
    var at = VK.now

    func accepts(now: Double, visible: Bool, fullAccess: Bool, acknowledged: String?) -> Bool {
        visible && fullAccess && now >= at && now - at < 2 && acknowledged != id
    }
}
