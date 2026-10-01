// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoiceKey",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "COpus",
            linkerSettings: [.unsafeFlags([Context.packageDirectory + "/build/opus/libopus.a"])]
        ),
        // 离线识别：在本进程内加载安卓 ELF so（仅 arm64 生效，x86_64 编译为空桩）
        .target(name: "CHanbao", cSettings: [.unsafeFlags(["-O2", "-Wno-unused-function"])]),
        .executableTarget(name: "VoiceKey", dependencies: ["COpus", "CHanbao"]),
    ],
    swiftLanguageModes: [.v5]
)
