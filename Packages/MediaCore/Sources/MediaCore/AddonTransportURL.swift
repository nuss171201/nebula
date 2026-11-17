import Foundation

/// Why a string the user typed could not be turned into an add-on manifest URL.
public enum AddonURLError: Error, Equatable, Sendable {
    case empty
    case malformed
    case unsupportedScheme(String)
    /// Plain HTTP is only accepted for add-ons running on this machine.
    case insecureHost(String)
}

/// A validated, normalised location of an add-on's `manifest.json`.
///
/// Accepts what users actually paste: an `https://` URL, the protocol's custom-scheme
/// install link, a bare host, or a URL that stops short of `/manifest.json`.
public struct AddonTransportURL: Hashable, Sendable, Codable {
    private static let manifestFileName = "manifest.json"
    private static let installScheme = "stremio"

    public let manifestURL: URL

    /// The URL that resource paths (`catalog/…`, `meta/…`, `stream/…`) are appended to.
    public var baseURL: URL {
        manifestURL.deletingLastPathComponent()
    }

    public init(userInput: String) throws(AddonURLError) {
        var text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }
        if !text.contains("://") {
            text = "https://" + text
        }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { throw .malformed }

        switch scheme {
        case "https":
            break
        case Self.installScheme:
            components.scheme = "https"
        case "http":
            guard Self.isLoopback(host) else { throw .insecureHost(host) }
        default:
            throw .unsupportedScheme(scheme)
        }

        // Work on the percent-encoded path so configuration segments reach the server
        // byte-for-byte as the user pasted them.
        components.percentEncodedPath = Self.manifestPath(from: components.percentEncodedPath)
        components.fragment = nil

        guard let url = components.url else { throw .malformed }
        manifestURL = url
    }

    /// Ensures the path ends in `/manifest.json`, collapsing any trailing slashes first.
    private static func manifestPath(from path: String) -> String {
        let suffix = "/" + manifestFileName
        guard !path.hasSuffix(suffix) else { return path }
        var trimmed = path
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed + suffix
    }

    private static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    }
}
