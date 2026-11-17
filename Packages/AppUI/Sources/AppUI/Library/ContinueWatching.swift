import Foundation
import MediaCore
import MediaLibrary
import Observation

/// One card on the Continue Watching row.
public struct ContinueItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Started and not finished: carry on where it was left.
        case resume
        /// The previous episode was finished: this is the next one.
        case nextEpisode
    }

    public var video: WatchVideo
    public var kind: Kind
    /// How far through it is, 0 to 1, for a resume card with a known length.
    public var progress: Double?
    /// Seconds left, when known.
    public var remaining: Double?

    public init(video: WatchVideo, kind: Kind, progress: Double? = nil, remaining: Double? = nil) {
        self.video = video
        self.kind = kind
        self.progress = progress
        self.remaining = remaining
    }

    public var id: String {
        "\(video.type.rawValue)|\(video.titleID)"
    }

    /// "S2 · E5 — The Title", or `nil` for a film.
    public var episodeLine: String? {
        guard let season = video.season, let episode = video.episode else { return video.videoTitle }
        let number = season == 0 ? "Special \(episode)" : "S\(season) · E\(episode)"
        return video.videoTitle.map { "\(number) — \($0)" } ?? number
    }

    /// "Next episode", "25 min left", or "Resume".
    public var statusLine: String {
        switch kind {
        case .nextEpisode:
            return "Next episode"
        case .resume:
            guard let remaining, remaining >= 60 else { return remaining == nil ? "Resume" : "Less than a minute left" }
            let minutes = Int((remaining / 60).rounded())
            return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
        }
    }
}

/// The rules behind the Continue Watching row.
public enum ContinueWatching {
    /// The episode that follows `current` in a series: the next one in the same season, else the
    /// first of the next season; only one that has aired. Specials (season 0) are not "next"
    /// after a regular episode, and nothing follows a special.
    public static func nextEpisode(after current: WatchVideo, in videos: [MetaVideo], now: Date = Date()) -> MetaVideo? {
        guard let season = current.season, let episode = current.episode, season > 0 else { return nil }
        return videos
            .filter { video in
                guard let videoSeason = video.season, let videoEpisode = video.episode, videoSeason > 0 else { return false }
                return (videoSeason, videoEpisode) > (season, episode)
            }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
            .first
            .flatMap { next in
                // The very next one must be out: skipping ahead past an unaired episode would be wrong.
                (next.released ?? .distantPast) <= now ? next : nil
            }
    }

    /// The card for a title's most recently watched video, if it has one: resume it if it is
    /// unfinished; if it is a finished episode, offer the next (looked up with `videos`, the
    /// series' episode list, when the caller has it).
    public static func item(for entry: WatchEntry, videos: [MetaVideo]?, now: Date = Date()) -> ContinueItem? {
        if entry.isInProgress {
            let remaining = entry.duration.map { max($0 - entry.position, 0) }
            return ContinueItem(video: entry.video, kind: .resume, progress: entry.progress, remaining: remaining)
        }
        guard entry.isWatched, let videos, let next = nextEpisode(after: entry.video, in: videos, now: now) else { return nil }
        var video = entry.video
        video.videoID = next.id
        video.season = next.season
        video.episode = next.episode
        video.videoTitle = next.title
        return ContinueItem(video: video, kind: .nextEpisode, progress: nil, remaining: nil)
    }
}

/// The Continue Watching row: for each title watched lately, where to pick it up.
@MainActor
@Observable
public final class ContinueWatchingModel {
    public private(set) var items: [ContinueItem] = []

    @ObservationIgnored private let library: LibraryCenter
    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private var addons: [InstalledAddon] = []
    /// Episode lists already fetched, by series id.
    @ObservationIgnored private var episodes: [String: [MetaVideo]] = [:]
    @ObservationIgnored private var generation = 0

    public init(library: LibraryCenter, client: AddonClient) {
        self.library = library
        self.client = client
    }

    public func update(addons: [InstalledAddon]) {
        self.addons = addons
    }

    /// Reads the history again. Unfinished videos appear at once; "next episode" cards need the
    /// series' episode list and appear when it has been fetched.
    public func reload(now: Date = Date()) async {
        generation += 1
        let current = generation
        let latest = await library.latestPerTitle()
        guard current == generation else { return }
        items = latest.compactMap { ContinueWatching.item(for: $0, videos: episodes[$0.video.titleID], now: now) }

        let finished = latest.filter { $0.isWatched && $0.video.season != nil && episodes[$0.video.titleID] == nil }
        guard !finished.isEmpty else { return }
        await withTaskGroup(of: (String, [MetaVideo]?).self) { group in
            for entry in finished {
                let providers = addons.serving(resource: ManifestResource.meta, type: entry.video.type, id: entry.video.titleID)
                group.addTask { [client] in
                    for provider in providers {
                        if let meta = try? await client.meta(type: entry.video.type, id: entry.video.titleID, from: provider.address) {
                            return (entry.video.titleID, meta.videos)
                        }
                    }
                    return (entry.video.titleID, nil)
                }
            }
            for await (titleID, videos) in group {
                episodes[titleID] = videos
            }
        }
        guard current == generation else { return }
        items = latest.compactMap { ContinueWatching.item(for: $0, videos: episodes[$0.video.titleID], now: now) }
    }

    /// Takes a title off the row.
    public func dismiss(_ item: ContinueItem) async {
        items.removeAll { $0.id == item.id }
        await library.dismissFromContinueWatching(type: item.video.type, titleID: item.video.titleID)
    }
}

/// The Library screen: saved titles, and the history of what was watched.
@MainActor
@Observable
public final class LibraryModel {
    public enum Tab: String, Sendable, CaseIterable, Identifiable {
        case saved, history

        public var id: Self { self }

        public var title: String {
            self == .saved ? "Saved" : "History"
        }
    }

    public var tab = Tab.saved
    /// `nil` shows every type.
    public var typeFilter: MediaType? {
        didSet {
            if typeFilter != oldValue {
                Task { await reload() }
            }
        }
    }

    public var order = LibraryStore.Order.recentlyAdded {
        didSet {
            if order != oldValue {
                Task { await reload() }
            }
        }
    }

    public private(set) var items: [LibraryItem] = []
    public private(set) var history: [WatchEntry] = []
    /// The types that have saved titles, for the filter.
    public private(set) var availableTypes: [MediaType] = []
    public private(set) var hasLoaded = false

    @ObservationIgnored private let library: LibraryCenter

    public init(library: LibraryCenter) {
        self.library = library
    }

    public func reload() async {
        let all = await library.items(order: order)
        var seen = Set<MediaType>()
        availableTypes = all.map(\.type).filter { seen.insert($0).inserted }.sorted(by: MediaType.displayOrder)
        if let typeFilter, !availableTypes.contains(typeFilter) {
            self.typeFilter = nil
        }
        items = typeFilter.map { type in all.filter { $0.type == type } } ?? all
        history = await library.watchHistory()
        hasLoaded = true
    }

    public func remove(_ item: LibraryItem) async {
        items.removeAll { $0.id == item.id && $0.type == item.type }
        await library.remove(type: item.type, id: item.id)
    }

    public func clearHistory() async {
        history = []
        await library.clearHistory()
    }
}

public extension LibraryItem {
    /// The saved title as the catalog would list it, for poster cards and navigation.
    var metaItem: MetaItem {
        MetaItem(
            id: id,
            type: type,
            name: name,
            poster: poster,
            posterShape: posterShape.flatMap(PosterShape.init(rawValue:)) ?? .poster,
            releaseInfo: releaseInfo
        )
    }
}
