// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PlayerKit", targets: ["PlayerKit"]),
    ],
    dependencies: [
        .package(path: "../MediaCore"),
    ],
    targets: [
        .target(name: "PlayerKit", dependencies: ["MediaCore"], swiftSettings: strictSettings),
        .testTarget(name: "PlayerKitTests", dependencies: ["PlayerKit"], swiftSettings: strictSettings),
    ]
)
