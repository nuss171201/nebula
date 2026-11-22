/// A content type in the add-on protocol.
///
/// The protocol lets add-ons declare arbitrary type strings, so this is an open
/// string wrapper with constants for the well-known types rather than a closed enum.
public struct MediaType: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let movie = MediaType(rawValue: "movie")
    public static let series = MediaType(rawValue: "series")
    /// Not one of the protocol's own types, but the one anime catalogs have agreed on.
    public static let anime = MediaType(rawValue: "anime")
    public static let channel = MediaType(rawValue: "channel")
    public static let tv = MediaType(rawValue: "tv")

    /// The types the app knows how to present with a dedicated UI, in display order.
    public static let wellKnown: [MediaType] = [.movie, .series, .anime, .channel, .tv]

    public var isWellKnown: Bool {
        Self.wellKnown.contains(self)
    }
}
