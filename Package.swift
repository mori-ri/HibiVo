// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HibiVo",
    defaultLocalization: "ja",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HibiVo", targets: ["HibiVo"])
    ],
    targets: [
        // Thin entry point. Everything else lives in HibiVoKit so it can be tested.
        .executableTarget(
            name: "HibiVo",
            dependencies: ["HibiVoKit"]
        ),
        .target(
            name: "HibiVoKit"
        ),
        .testTarget(
            name: "HibiVoKitTests",
            dependencies: ["HibiVoKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
