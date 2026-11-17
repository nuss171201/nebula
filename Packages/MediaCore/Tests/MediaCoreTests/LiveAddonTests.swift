import Foundation
@testable import MediaCore
import Testing

/// Opt-in checks against the real default add-ons, to catch protocol drift.
/// Skipped unless `LIVE_ADDON_TESTS=1`, so CI never depends on the network:
///
///     LIVE_ADDON_TESTS=1 swift test --filter LiveAddonTests
@Suite(
    "Live default add-ons",
    .enabled(if: ProcessInfo.processInfo.environment["LIVE_ADDON_TESTS"] == "1")
)
struct LiveAddonTests {
    private let client = AddonClient(http: URLSessionHTTPClient(userAgent: "MediaCoreTests/1.0"))

    private func cinemeta() throws -> AddonTransportURL {
        try AddonTransportURL(userInput: "https://v3-cinemeta.strem.io/manifest.json")
    }

    @Test("Cinemeta manifest, a catalog page, a search and both kinds of meta parse")
    func cinemetaEndToEnd() async throws {
        let address = try cinemeta()

        let manifest = try await client.manifest(at: address)
        #expect(manifest.supports(resource: ManifestResource.catalog))
        #expect(manifest.supports(resource: ManifestResource.meta, type: .movie, id: "tt0111161"))
        #expect(manifest.catalogs.contains { $0.isBoardEligible })
        #expect(manifest.catalogs.contains { $0.isSearchable })

        let page = try await client.catalog(CatalogRequest(type: .movie, catalogID: "top"), from: address)
        #expect(page.items.count >= 20)
        #expect(page.items.allSatisfy { $0.poster != nil })

        let next = try await client.catalog(
            CatalogRequest(type: .movie, catalogID: "top", skip: page.items.count),
            from: address
        )
        #expect(Set(next.items.map(\.id)).isDisjoint(with: page.items.map(\.id)))

        let results = try await client.catalog(
            CatalogRequest(type: .series, catalogID: "top", extra: [.init("search", "the office")]),
            from: address
        )
        #expect(!results.items.isEmpty)

        let movie = try await client.meta(type: .movie, id: "tt0111161", from: address)
        #expect(movie.imdbRating != nil)
        #expect(!movie.cast.isEmpty)
        #expect(!movie.trailers.isEmpty)

        let series = try await client.meta(type: .series, id: "tt0386676", from: address)
        #expect(series.videos.count > 100)
        #expect(series.videos.contains { $0.season == 1 && $0.episode == 1 })

        await #expect(throws: AddonError.notFound) {
            try await client.meta(type: .movie, id: "tt0000000000", from: address)
        }
    }

    @Test("OpenSubtitles manifest parses and offers subtitles")
    func openSubtitles() async throws {
        let address = try AddonTransportURL(userInput: "https://opensubtitles-v3.strem.io/manifest.json")
        let manifest = try await client.manifest(at: address)
        #expect(manifest.supports(resource: ManifestResource.subtitles, type: .movie, id: "tt0111161"))

        let subtitles = try await client.subtitles(type: .movie, videoID: "tt0111161", from: address)
        #expect(!subtitles.isEmpty)
    }
}
