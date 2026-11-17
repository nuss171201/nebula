// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "MediaCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"]),
    ],
    targets: [
        .target(name: "MediaCore", swiftSettings: strictSettings),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"], swiftSettings: strictSettings),
    ]
)
