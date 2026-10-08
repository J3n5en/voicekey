// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoiceKeyCore",
    platforms: [.iOS(.v17)],
    products: [.library(name: "VoiceKeyCore", targets: ["VoiceKeyCore"])],
    targets: [
        // 由 build-xcframework.sh 生成
        .binaryTarget(name: "VoiceKeyCoreFFI", path: "VoiceKeyCoreFFI.xcframework"),
        .target(
            name: "VoiceKeyCore",
            dependencies: ["VoiceKeyCoreFFI"],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedLibrary("iconv"),
            ]
        ),
        .testTarget(name: "VoiceKeyCoreTests", dependencies: ["VoiceKeyCore"]),
    ]
)
