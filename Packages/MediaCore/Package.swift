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
        // A local mock add-on server and fixtures, for tests in this and other packages.
        .library(name: "AddonTestSupport", targets: ["AddonTestSupport"]),
    ],
    targets: [
        .target(name: "MediaCore", swiftSettings: strictSettings),
        .target(name: "AddonTestSupport", dependencies: ["MediaCore"], swiftSettings: strictSettings),
        .testTarget(
            name: "MediaCoreTests",
            dependencies: ["MediaCore", "AddonTestSupport"],
            swiftSettings: strictSettings
        ),
    ]
)
