// swift-tools-version: 6.2
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error),
    .enableUpcomingFeature("ExistentialAny"),
]

/// What libtorrent was built with, as recorded by Scripts/build-torrent-framework.sh in
/// Vendor/Libtorrent.xcframework/public-defines.txt. Code that includes its headers must be
/// compiled with the same definitions; libtorrent checks that they agree when linking.
let libtorrentDefines: [CXXSetting] = [
    "BOOST_ASIO_ENABLE_CANCELIO", "BOOST_ASIO_NO_DEPRECATED", "TORRENT_NO_DEPRECATE",
    "TORRENT_USE_OPENSSL", "TORRENT_USE_LIBCRYPTO", "TORRENT_SSL_PEERS",
    "OPENSSL_NO_SSL2", "OPENSSL_NO_SSL3", "OPENSSL_NO_TLS1", "OPENSSL_NO_TLS1_1", "OPENSSL_NO_DTLS1",
].map { .define($0) }

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
        // libtorrent-rasterbar with OpenSSL, static, produced by Scripts/build-torrent-framework.sh
        // (not committed). Its headers are C++ and are only ever seen by TorrentBridge.
        .binaryTarget(name: "Libtorrent", path: "Vendor/Libtorrent.xcframework"),
        // Objective-C++ on the inside, plain Objective-C on the outside.
        .target(
            name: "TorrentBridge",
            dependencies: ["Libtorrent"],
            cxxSettings: libtorrentDefines,
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .target(name: "StreamEngine", dependencies: ["MediaCore", "TorrentBridge"], swiftSettings: strictSettings),
        .testTarget(name: "StreamEngineTests", dependencies: ["StreamEngine"], swiftSettings: strictSettings),
    ],
    cxxLanguageStandard: .cxx17
)
