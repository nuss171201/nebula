import Foundation
import MediaCore

/// A film or series found when the user tells the player what a file is.
public struct SubtitleTitleMatch: Sendable, Hashable, Identifiable {
    /// The catalog's id for the title, for example `tt0063350`.
    public var id: String
    public var type: MediaType
    public var name: String
    /// The year or run of years, as the catalog writes it.
    public var year: String?

    public init(id: String, type: MediaType, name: String, year: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.year = year
    }

    /// "Film", "Series", or the catalog's own word for other kinds.
    public var kindName: String {
        switch type {
        case .movie: "Film"
        case .series: "Series"
        default: type.rawValue.capitalized
        }
    }
}

/// The exact video subtitles are wanted for: a film, or one episode of a series.
public struct SubtitleVideo: Sendable, Hashable {
    public var type: MediaType
    /// The title's id for films; `id:season:episode` for episodes.
    public var videoID: String

    public init(type: MediaType, videoID: String) {
        self.type = type
        self.videoID = videoID
    }

    public init(title: SubtitleTitleMatch, season: Int, episode: Int) {
        self.init(type: title.type, videoID: title.type == .series ? "\(title.id):\(season):\(episode)" : title.id)
    }
}

/// What is known about the file itself, which lets a provider find subtitles timed for exactly this release.
public struct SubtitleFileHints: Sendable, Hashable {
    public var fileName: String?
    public var fingerprint: VideoFileHash.Fingerprint?

    public init(fileName: String? = nil, fingerprint: VideoFileHash.Fingerprint? = nil) {
        self.fileName = fileName
        self.fingerprint = fingerprint
    }
}

/// One subtitle a provider offers.
public struct OnlineSubtitle: Sendable, Hashable, Identifiable {
    /// Unique across providers.
    public var id: String
    public var url: URL
    /// Language as the provider gives it.
    public var language: String
    /// The release it was timed for, when known.
    public var releaseName: String?
    public var providerName: String

    public init(id: String, url: URL, language: String, releaseName: String? = nil, providerName: String) {
        self.id = id
        self.url = url
        self.language = language
        self.releaseName = releaseName
        self.providerName = providerName
    }
}

public enum OnlineSubtitleError: Error, Sendable, Equatable {
    /// Nothing installed can do this.
    case noProvider
    /// Carries a sentence for the user.
    case failed(String)
    case cancelled

    public var userMessage: String {
        switch self {
        case .noProvider: "No installed add-on offers this. Add a subtitle or catalog add-on in Add-ons."
        case let .failed(message): message
        case .cancelled: "Cancelled."
        }
    }
}

/// Where the player gets subtitles from the network. Implemented by the app on top of the
/// add-ons the user has installed; the player knows nothing about add-ons.
public protocol OnlineSubtitleService: Sendable {
    /// Films and series whose name matches `query`, best first.
    func titles(matching query: String) async throws(OnlineSubtitleError) -> [SubtitleTitleMatch]
    /// Subtitles for a video, from every provider that has any.
    func subtitles(for video: SubtitleVideo, file: SubtitleFileHints) async throws(OnlineSubtitleError) -> [OnlineSubtitle]
    /// Fetches a subtitle and returns the local file it was saved to.
    func download(_ subtitle: OnlineSubtitle) async throws(OnlineSubtitleError) -> URL
}

/// Subtitles in one language, for display.
public struct SubtitleLanguageGroup: Sendable, Hashable, Identifiable {
    /// The provider's language tag, lower-cased.
    public var id: String
    public var name: String
    public var subtitles: [OnlineSubtitle]

    /// Tags some subtitle databases use that are not language codes.
    private static let providerTags: [String: (name: String, language: String)] = [
        "pob": ("Portuguese (Brazil)", "pt"),
        "pb": ("Portuguese (Brazil)", "pt"),
        "zht": ("Chinese (Traditional)", "zh"),
        "zhc": ("Chinese (Cantonese)", "zh"),
        "zhe": ("Chinese (Bilingual)", "zh"),
        "spl": ("Spanish (Latin America)", "es"),
        "spn": ("Spanish (Spain)", "es"),
    ]

    /// Groups by language: the user's languages first, in their order of preference, then
    /// the rest by name. Within a language the provider's order is kept.
    public static func groups(of subtitles: [OnlineSubtitle], preferredLanguages: [String], locale: Locale = .current) -> [SubtitleLanguageGroup] {
        var order: [String] = []
        var byTag: [String: [OnlineSubtitle]] = [:]
        for subtitle in subtitles {
            let tag = subtitle.language.lowercased()
            if byTag[tag] == nil {
                order.append(tag)
            }
            byTag[tag, default: []].append(subtitle)
        }
        let preferred = preferredLanguages.compactMap(LanguageMatcher.canonical)
        func rank(_ tag: String) -> Int {
            let language = LanguageMatcher.canonical(providerTags[tag]?.language ?? tag)
            return language.flatMap(preferred.firstIndex(of:)) ?? Int.max
        }
        return order
            .map { tag in
                let name = providerTags[tag]?.name ?? LanguageMatcher.displayName(for: tag, locale: locale) ?? tag.uppercased()
                return SubtitleLanguageGroup(id: tag, name: name, subtitles: byTag[tag] ?? [])
            }
            .sorted { lhs, rhs in
                let (left, right) = (rank(lhs.id), rank(rhs.id))
                return left != right ? left < right : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
