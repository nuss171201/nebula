import Foundation
import MediaCore
import MediaLibrary
import Observation

/// The detail page of one title: full metadata, and for series the seasons and episodes.
@MainActor
@Observable
public final class DetailModel {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    public let route: MediaRoute
    /// The catalog preview at first, replaced by the full metadata once loaded.
    public private(set) var meta: MetaItem?
    public private(set) var phase: Phase = .loading
    /// Season numbers in display order: regular seasons ascending, specials (season 0) last.
    public private(set) var seasons: [Int] = []
    public var selectedSeason: Int?
    /// The streams of the film, or of the episode whose streams are showing.
    public let streams: StreamListModel
    /// The episode whose streams are showing, if any.
    public private(set) var selectedVideoID: String?
    /// Whether the title is saved in the library.
    public private(set) var isInLibrary = false
    /// What has been watched of this title, by video id.
    public private(set) var watchEntries: [String: WatchEntry] = [:]

    /// An episode to show the streams of as soon as the page has loaded.
    @ObservationIgnored public var initialVideoID: String?
    /// Set when the page was opened by a Play button elsewhere (the Home banner): a series
    /// opens on the episode to carry on with, and the page plays once it has streams
    /// (`AppModel.playWhenReady`).
    @ObservationIgnored public var startsPlaying = false
    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private let library: LibraryCenter?
    @ObservationIgnored private var addons: [InstalledAddon] = []

    public init(
        route: MediaRoute,
        client: AddonClient,
        streamMemory: (any StreamChoiceMemory)? = nil,
        library: LibraryCenter? = nil
    ) {
        self.route = route
        self.client = client
        self.library = library
        streams = StreamListModel(client: client, memory: streamMemory)
        meta = route.preview
        streams.setRuntime(RuntimeText.seconds(in: route.preview?.runtime))
    }

    // MARK: - Library and watched marks

    /// Reads again whether the title is saved and what has been watched of it.
    public func refreshLibraryState() async {
        guard let library else { return }
        isInLibrary = await library.isSaved(type: route.type, id: route.id)
        watchEntries = await library.entries(type: route.type, titleID: route.id)
    }

    /// Saves the title to the library, or takes it out.
    public func toggleLibrary() async {
        guard let library, let meta else { return }
        if isInLibrary {
            await library.remove(type: route.type, id: route.id)
        } else {
            await library.save(meta)
        }
        await refreshLibraryState()
    }

    public func isWatched(_ video: MetaVideo) -> Bool {
        watchEntries[video.id]?.isWatched ?? false
    }

    /// How far through an episode is, 0 to 1, if it was started and not finished.
    public func progress(of video: MetaVideo) -> Double? {
        guard let entry = watchEntries[video.id], entry.isInProgress else { return nil }
        return entry.progress
    }

    /// Whether the film itself (a title that is one video) has been watched.
    public var isTitleWatched: Bool {
        watchEntries[route.id]?.isWatched ?? false
    }

    /// Whether every episode of the selected season that has aired is watched.
    public var isSeasonWatched: Bool {
        let aired = airedEpisodesOfSelectedSeason
        return !aired.isEmpty && aired.allSatisfy(isWatched)
    }

    /// Marks an episode as watched or not; `nil` means the film itself.
    public func setWatched(_ isWatched: Bool, video: MetaVideo? = nil) async {
        guard let library, let watchVideo = watchVideo(for: video) else { return }
        await library.setWatched(isWatched, videos: [watchVideo])
        await refreshLibraryState()
    }

    /// Marks every episode of the selected season that has aired.
    public func setSeasonWatched(_ isWatched: Bool) async {
        guard let library else { return }
        await library.setWatched(isWatched, videos: airedEpisodesOfSelectedSeason.compactMap { watchVideo(for: $0) })
        await refreshLibraryState()
    }

    private var airedEpisodesOfSelectedSeason: [MetaVideo] {
        let now = Date()
        return episodes.filter { ($0.released ?? .distantPast) <= now }
    }

    /// A video of this title as the watch history files it; `nil` (the film) before the page has loaded.
    func watchVideo(for video: MetaVideo?) -> WatchVideo? {
        guard let meta else { return nil }
        return WatchVideo(
            type: route.type,
            videoID: video?.id ?? route.id,
            titleID: route.id,
            titleName: meta.name,
            poster: meta.poster,
            season: video?.season,
            episode: video?.episode,
            videoTitle: video?.title
        )
    }

    /// Whether the title is one video (a film, a channel) rather than a list of episodes.
    public var isSingleVideo: Bool {
        phase == .loaded && (meta?.videos.isEmpty ?? true)
    }

    /// The video whose streams are showing, as the stream player needs it.
    public var streamVideo: StreamVideo? {
        guard let videoID = streams.videoID else { return nil }
        let episode = meta?.videos.first { $0.id == videoID }
        let name = [title, episode?.numberedTitle].compactMap(\.self).joined(separator: " — ")
        return StreamVideo(
            type: route.type,
            videoID: videoID,
            titleID: route.id,
            title: name,
            titleName: title,
            poster: meta?.poster,
            season: episode?.season,
            episode: episode?.episode,
            episodeTitle: episode?.title
        )
    }

    /// Shows an episode's streams under it, or hides them if they are showing.
    public func toggleStreams(for video: MetaVideo) {
        if selectedVideoID == video.id {
            selectedVideoID = nil
            streams.clear()
        } else {
            selectedVideoID = video.id
            streams.load(type: route.type, videoID: video.id, titleID: route.id, addons: addons)
        }
    }

    public var title: String {
        meta?.name ?? ""
    }

    /// Episodes of the selected season, in episode order.
    public var episodes: [MetaVideo] {
        guard let selectedSeason, let meta else { return [] }
        return meta.videos
            .filter { $0.season == selectedSeason }
            .sorted { ($0.episode ?? .max, $0.released ?? .distantFuture) < ($1.episode ?? .max, $1.released ?? .distantFuture) }
    }

    /// Videos that are not part of a season (a channel's uploads), newest first.
    public var looseVideos: [MetaVideo] {
        guard let meta else { return [] }
        return meta.videos
            .filter { $0.season == nil }
            .sorted { ($0.released ?? .distantPast) > ($1.released ?? .distantPast) }
    }

    public var trailer: MetaTrailer? {
        meta?.trailers.first
    }

    /// The episode Play starts a series on: the one watched last if it was not finished, else
    /// the one after it; for a series never started (or watched to its end), the first episode
    /// of the first season that has aired. `nil` for a title with no numbered episodes.
    public nonisolated static func episodeToStart(in videos: [MetaVideo], entries: [String: WatchEntry], now: Date = Date()) -> MetaVideo? {
        if let latest = entries.values.max(by: { $0.lastWatchedAt < $1.lastWatchedAt }),
           let video = videos.first(where: { $0.id == latest.video.videoID }) {
            if !latest.isWatched {
                return video
            }
            if let next = ContinueWatching.nextEpisode(after: latest.video, in: videos, now: now) {
                return next
            }
        }
        return videos
            .filter { ($0.season ?? 0) > 0 && $0.episode != nil && ($0.released ?? .distantPast) <= now }
            .min { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }

    public nonisolated static func seasonTitle(_ season: Int) -> String {
        season == 0 ? "Specials" : "Season \(season)"
    }

    /// An episode's date, marked as upcoming when it has not aired yet.
    public nonisolated static func releaseText(for released: Date, now: Date = Date()) -> String {
        let date = released.formatted(date: .abbreviated, time: .omitted)
        return released > now ? "Airs \(date)" : date
    }

    /// Asks each add-on that serves metadata for this title, in order, until one answers.
    public func load(addons: [InstalledAddon]) async {
        self.addons = addons
        phase = .loading
        await refreshLibraryState()
        let providers = addons.serving(resource: ManifestResource.meta, type: route.type, id: route.id)
        guard !providers.isEmpty else {
            phase = .failed("None of your add-ons provides details for this title.")
            return
        }

        var lastError: AddonError = .notFound
        for provider in providers {
            do {
                let full = try await client.meta(type: route.type, id: route.id, from: provider.address)
                apply(full)
                return
            } catch {
                if error.isCancellation {
                    return
                }
                lastError = error
            }
        }
        phase = .failed(lastError.userMessage)
    }

    private func apply(_ full: MetaItem) {
        meta = full
        streams.setRuntime(RuntimeText.seconds(in: full.runtime))
        let numbers = Set(full.videos.compactMap(\.season))
        seasons = numbers.filter { $0 != 0 }.sorted() + (numbers.contains(0) ? [0] : [])
        if selectedSeason.map(seasons.contains) != true {
            selectedSeason = seasons.first
        }
        if let wanted = initialVideoID, let video = full.videos.first(where: { $0.id == wanted }) {
            // Opened for this episode: show its season, and its streams below.
            initialVideoID = nil
            selectedSeason = video.season ?? selectedSeason
            selectedVideoID = wanted
        }
        if startsPlaying, selectedVideoID == nil, let episode = Self.episodeToStart(in: full.videos, entries: watchEntries) {
            selectedSeason = episode.season ?? selectedSeason
            selectedVideoID = episode.id
        }
        phase = .loaded
        if full.videos.isEmpty {
            // One video: its streams are the page's streams.
            streams.load(type: route.type, videoID: route.id, titleID: route.id, addons: addons)
        } else if let selectedVideoID, full.videos.contains(where: { $0.id == selectedVideoID }) {
            // The add-ons changed while an episode's streams were showing.
            streams.load(type: route.type, videoID: selectedVideoID, titleID: route.id, addons: addons)
        }
    }
}
