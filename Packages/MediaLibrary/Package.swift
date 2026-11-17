// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "MediaLibrary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MediaLibrary", targets: ["MediaLibrary"]),
    ],
    dependencies: [
        .package(path: "../MediaCore"),
        // Pinned exactly: the generated Xcode project (and its Package.resolved) is not committed.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
    ],
    targets: [
        .target(
            name: "MediaLibrary",
            dependencies: [
                "MediaCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "MediaLibraryTests", dependencies: ["MediaLibrary"], swiftSettings: strictSettings),
    ]
)
