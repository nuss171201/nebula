// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "StreamEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StreamEngine", targets: ["StreamEngine"]),
    ],
    dependencies: [
        .package(path: "../MediaCore"),
    ],
    targets: [
        .target(name: "StreamEngine", dependencies: ["MediaCore"], swiftSettings: strictSettings),
        .testTarget(name: "StreamEngineTests", dependencies: ["StreamEngine"], swiftSettings: strictSettings),
    ]
)
