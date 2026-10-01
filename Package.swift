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
        .executableTarget(name: "VoiceKey", dependencies: ["COpus"]),
    ],
    swiftLanguageModes: [.v5]
)
