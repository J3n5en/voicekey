import XCTest

final class AppGroupTests: XCTestCase {
    private let d = Bus.defaultGroup

    func testNormalSigningKeepsDefaultGroupWithoutReadingProfile() {
        var read = false
        let g = Bus.resolveGroup(canOpen: { $0 == self.d }) { read = true; return ["group.other"] }
        XCTAssertEqual(g, d)
        XCTAssertFalse(read)
    }

    func testRenamedGroupPrefersDefaultPrefixThenVoiceKey() {
        let renamed = d + ".ABCDE12345", other = "group.x.VoiceKey", junk = "group.aaa"
        let all = [junk, other, renamed]
        XCTAssertEqual(Bus.resolveGroup(canOpen: { $0 != self.d }) { all }, renamed)
        XCTAssertEqual(Bus.resolveGroup(canOpen: { $0 != self.d && $0 != renamed }) { all + all }, other)
        XCTAssertEqual(Bus.resolveGroup(canOpen: { $0 == junk }) { all }, junk)
    }

    func testFallsBackToDefaultWhenNothingOpens() {
        XCTAssertEqual(Bus.resolveGroup(canOpen: { _ in false }) { ["group.a", "group.b"] }, d)
        XCTAssertEqual(Bus.resolveGroup(canOpen: { _ in false }) { [] }, d)
    }

    func testProvisionedGroupsReadsOnlyEmbeddedProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(Bus.provisionedGroups(in: dir), [])

        let plist: [String: Any] = ["Entitlements": ["com.apple.security.application-groups": ["group.re.signed", d + ".X"]]]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // 描述文件是 CMS 签名包，plist 夹在二进制前后缀中间
        var blob = Data([0x30, 0x82, 0xff, 0x00])
        blob.append(xml)
        blob.append(Data([0x00, 0xa0, 0x82]))
        try blob.write(to: dir.appendingPathComponent("embedded.mobileprovision"))
        XCTAssertEqual(Bus.provisionedGroups(in: dir), ["group.re.signed", d + ".X"])

        try Data("garbage".utf8).write(to: dir.appendingPathComponent("embedded.mobileprovision"))
        XCTAssertEqual(Bus.provisionedGroups(in: dir), [])
    }
}
