import Foundation

/// The app's identity as seen by code. The values originate in `Config/Branding.xcconfig`
/// and reach the process through the bundle's Info.plist; nothing else hard-codes them.
public struct AppBranding: Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let version: String
    public let build: String

    public init(name: String, bundleIdentifier: String, version: String, build: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
    }

    /// Reads the identity from a bundle's Info.plist, falling back to neutral values
    /// when a key is missing (for example in a unit-test host).
    public init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        let displayName = info["CFBundleDisplayName"] as? String
        let bundleName = info["CFBundleName"] as? String
        self.init(
            name: displayName ?? bundleName ?? "App",
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown.bundle",
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0"
        )
    }

    /// Value for the HTTP `User-Agent` header on every outgoing request.
    public var userAgent: String {
        "\(name)/\(version) (macOS; build \(build))"
    }
}
