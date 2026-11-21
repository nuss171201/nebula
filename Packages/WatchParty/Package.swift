// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "WatchParty",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WatchParty", targets: ["WatchParty"]),
        // A signalling server on the loopback interface, for tests in this and other packages.
        .library(name: "WatchPartyTestSupport", targets: ["WatchPartyTestSupport"]),
    ],
    dependencies: [
        .package(path: "../MediaCore"),
        // Google's WebRTC as a prebuilt dynamic framework (BSD). Pinned exactly, like every other
        // dependency; the package names the archive's checksum, which the package manager verifies.
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "158.0.0"),
    ],
    targets: [
        .target(
            name: "WatchParty",
            dependencies: ["MediaCore", .product(name: "WebRTC", package: "WebRTC")],
            swiftSettings: strictSettings
        ),
        .target(name: "WatchPartyTestSupport", dependencies: ["WatchParty"], swiftSettings: strictSettings),
        .testTarget(
            name: "WatchPartyTests",
            dependencies: ["WatchParty", "WatchPartyTestSupport"],
            swiftSettings: strictSettings
        ),
    ]
)
