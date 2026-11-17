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
        // A dynamic build of libmpv, produced by Scripts/build-mpv-framework.sh (not committed).
        // Dynamic on purpose: see that script for the licensing reason.
        .binaryTarget(name: "Libmpv", path: "Vendor/Libmpv.xcframework"),
        .target(name: "PlayerKit", dependencies: ["MediaCore", "Libmpv"], swiftSettings: strictSettings),
        .testTarget(name: "PlayerKitTests", dependencies: ["PlayerKit"], swiftSettings: strictSettings),
    ]
)
