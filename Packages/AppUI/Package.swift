// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "AppUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppUI", targets: ["AppUI"]),
    ],
    dependencies: [
        .package(path: "../MediaCore"),
        .package(path: "../MediaLibrary"),
        .package(path: "../StreamEngine"),
        .package(path: "../PlayerKit"),
    ],
    targets: [
        .target(
            name: "AppUI",
            dependencies: ["MediaCore", "MediaLibrary", "StreamEngine", "PlayerKit"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "AppUITests",
            dependencies: [
                "AppUI",
                "MediaCore",
                "MediaLibrary",
                .product(name: "AddonTestSupport", package: "MediaCore"),
            ],
            swiftSettings: strictSettings
        ),
    ]
)
