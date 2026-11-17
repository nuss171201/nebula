import Foundation

/// Where the app looks for updates, and the key that proves an update is genuine.
///
/// Both come from `Config/Branding.xcconfig` through Info.plist. Without both, and in exactly
/// the right form, there is no updater at all: an app must never fetch and install code from
/// an address it cannot check.
public struct UpdateConfiguration: Sendable, Equatable {
    public let feedURL: URL
    /// The Ed25519 public key updates are signed with, in base64.
    public let publicKey: String

    public init?(feedURL: String?, publicKey: String?) {
        guard let feedText = feedURL?.trimmingCharacters(in: .whitespacesAndNewlines), !feedText.isEmpty,
              let url = URL(string: feedText), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              // An Ed25519 public key is 32 bytes.
              Data(base64Encoded: key)?.count == 32
        else { return nil }
        self.feedURL = url
        self.publicKey = key
    }

    /// Reads `SUFeedURL` and `SUPublicEDKey`, the keys the updater itself reads.
    public init?(infoDictionary: [String: Any]?) {
        self.init(feedURL: infoDictionary?["SUFeedURL"] as? String, publicKey: infoDictionary?["SUPublicEDKey"] as? String)
    }
}
