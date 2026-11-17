import Foundation
import MediaCore
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

    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private var addons: [InstalledAddon] = []

    public init(route: MediaRoute, client: AddonClient, streamMemory: (any StreamChoiceMemory)? = nil) {
        self.route = route
        self.client = client
        streams = StreamListModel(client: client, memory: streamMemory)
        meta = route.preview
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
        return StreamVideo(type: route.type, videoID: videoID, titleID: route.id, title: name)
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
        let numbers = Set(full.videos.compactMap(\.season))
        seasons = numbers.filter { $0 != 0 }.sorted() + (numbers.contains(0) ? [0] : [])
        if selectedSeason.map(seasons.contains) != true {
            selectedSeason = seasons.first
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
