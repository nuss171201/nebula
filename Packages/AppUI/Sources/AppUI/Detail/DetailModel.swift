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

    @ObservationIgnored private let client: AddonClient

    public init(route: MediaRoute, client: AddonClient) {
        self.route = route
        self.client = client
        meta = route.preview
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

    public static func seasonTitle(_ season: Int) -> String {
        season == 0 ? "Specials" : "Season \(season)"
    }

    /// Asks each add-on that serves metadata for this title, in order, until one answers.
    public func load(addons: [InstalledAddon]) async {
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
    }
}
