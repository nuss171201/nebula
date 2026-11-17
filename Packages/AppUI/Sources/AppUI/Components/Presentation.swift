import Foundation
import MediaCore

/// The life cycle of something fetched from the network.
public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    /// Carries a sentence that can be shown to the user as-is.
    case failed(String)

    public var value: Value? {
        if case let .loaded(value) = self {
            value
        } else {
            nil
        }
    }

    public var errorMessage: String? {
        if case let .failed(message) = self {
            message
        } else {
            nil
        }
    }

    public var isLoading: Bool {
        if case .loading = self {
            true
        } else {
            false
        }
    }
}

extension LoadState: Equatable where Value: Equatable {}

/// A title to open on the detail page. The preview (from a catalog or search result)
/// lets the page show a name and poster before the full metadata arrives.
public struct MediaRoute: Hashable, Sendable {
    public var type: MediaType
    public var id: String
    public var preview: MetaItem?

    public init(type: MediaType, id: String, preview: MetaItem? = nil) {
        self.type = type
        self.id = id
        self.preview = preview
    }

    public init(item: MetaItem) {
        self.init(type: item.type, id: item.id, preview: item)
    }
}

public extension MediaType {
    /// Plural name for headings and pickers: "Movies", "Series", "Channels", "TV".
    var pluralTitle: String {
        switch self {
        case .movie: "Movies"
        case .series: "Series"
        case .channel: "Channels"
        case .tv: "TV"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Well-known types first, in their standard order; anything else after, alphabetically.
    static func displayOrder(_ lhs: MediaType, _ rhs: MediaType) -> Bool {
        let left = wellKnown.firstIndex(of: lhs) ?? Int.max
        let right = wellKnown.firstIndex(of: rhs) ?? Int.max
        return left == right ? lhs.rawValue < rhs.rawValue : left < right
    }
}

public extension MetaItem {
    /// Rating with one decimal, for example `8.4`.
    var ratingText: String? {
        imdbRating.map { String(format: "%.1f", $0) }
    }

    /// The short facts shown under a title: release, runtime, rating.
    var factLine: [String] {
        [releaseInfo, runtime, ratingText.map { "★ \($0)" }].compactMap(\.self)
    }
}

public extension MetaVideo {
    /// "3. Title" for numbered episodes, the bare title otherwise.
    var numberedTitle: String {
        episode.map { "\($0). \(title)" } ?? title
    }
}
