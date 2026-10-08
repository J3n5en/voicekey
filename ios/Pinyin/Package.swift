// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pinyin",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Pinyin", targets: ["Pinyin"])],
    targets: [
        // 由 build-xcframework.sh 生成
        .binaryTarget(name: "RimeFFI", path: "RimeFFI.xcframework"),
        // RimeData 由 build-data.sh 生成
        .target(name: "Pinyin", dependencies: ["RimeFFI"], resources: [.copy("RimeData")]),
        .testTarget(name: "PinyinTests", dependencies: ["Pinyin"]),
    ]
)
