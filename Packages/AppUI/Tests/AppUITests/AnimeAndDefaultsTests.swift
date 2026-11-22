import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary
import Testing

/// An add-on shaped like an anime catalog: catalogs of a type of its own, whose titles are series.
private let animeManifest = """
{"id": "test.anime", "version": "1.0.0", "name": "Anime Catalog", "resources": ["catalog", "meta"],
 "types": ["anime", "movie", "series"], "idPrefixes": ["kitsu"],
 "catalogs": [
   {"type": "anime", "id": "trending", "name": "Trending"},
   {"type": "anime", "id": "popular", "name": "Most Popular", "extra": [{"name": "genre", "options": ["Action"]}, {"name": "skip"}]},
   {"type": "anime", "id": "list", "name": "Search", "extra": [{"name": "search", "isRequired": true}]}
 ]}
"""

@MainActor
@Suite("The Anime section and the add-on it comes from")
struct AnimeTests {
    private func addons(_ harness: AddonHarness) async throws -> [InstalledAddon] {
        harness.server.respond(to: "/anime/manifest.json", with: .json(animeManifest))
        let address = try harness.address("anime")
        return try await [harness.installedAddon(), InstalledAddon(address: address, manifest: harness.client.manifest(at: address))]
    }

    @Test("A catalog is of anime if its type says so, or its name does")
    func recognisesAnime() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        let sources = try await addons(harness).catalogSources
        #expect(sources.filter(\.isAnime).map(\.catalog.id) == ["trending", "popular", "list"])
        #expect(sources.filter(\.isAnime).allSatisfy { $0.addon.manifest.name == "Anime Catalog" })

        // Some add-ons list anime among their series, and say so only in the catalog's name.
        var named = try #require(sources.first { !$0.isAnime })
        named.catalog.name = "Top Anime"
        #expect(named.isAnime)
    }

    @Test("Anime has a board of its own, and Home leaves it out")
    func boards() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        let addons = try await addons(harness)

        let home = HomeModel(client: harness.client) { !$0.isAnime }
        let anime = HomeModel(client: harness.client) { $0.isAnime }
        home.update(addons: addons)
        anime.update(addons: addons)
        // The search catalog needs a query, so it is no row.
        #expect(anime.rows.map(\.title) == ["Trending · Anime", "Most Popular · Anime"])
        #expect(!home.rows.isEmpty && home.rows.allSatisfy { !$0.source.isAnime })
        // With the anime add-on gone, its board is empty and Home is as it was.
        anime.update(addons: [addons[0]])
        #expect(anime.rows.isEmpty)
    }

    @Test("Discover offers Anime as a kind of its own, after films and series")
    func discover() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        let model = DiscoverModel(client: harness.client)
        try await model.update(addons: addons(harness))
        #expect(model.types.prefix(3) == [.movie, .series, .anime])
        #expect(MediaType.anime.pluralTitle == "Anime")
        harness.server.respond(to: "/anime/catalog/anime/trending.json", with: .json(#"{"metas": []}"#))
        model.select(type: .anime)
        #expect(model.catalogs.map(\.catalog.id) == ["trending", "popular"])
        await model.waitForLoading()
    }

    @Test("The sidebar has Anime and Downloads")
    func sections() {
        #expect(AppSection.allCases.map(\.title) == ["Home", "Discover", "Anime", "Library", "Downloads", "Calendar", "Add-ons"])
        #expect(AppSection(rawValue: "anime") == .anime && AppSection(rawValue: "downloads") == .downloads)
    }
}

@MainActor
@Suite("Default add-ons that came later")
struct DefaultAddonRoundTests {
    private func registry(_ harness: AddonHarness, defaults: [DefaultAddon]) -> AddonRegistry {
        AddonRegistry(
            client: harness.client,
            store: AddonStore(database: harness.database),
            settings: SettingsStore(database: harness.database),
            defaults: defaults
        )
    }

    @Test("A new profile gets every default; one that has the first round gets only what came after, once")
    func laterRounds() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        harness.serveSecondAddon(prefix: "subs", name: "Subtitles")
        harness.server.respond(to: "/anime/manifest.json", with: .json(animeManifest))
        let first = try [
            DefaultAddon(address: harness.address().manifestURL.absoluteString),
            DefaultAddon(address: harness.address("subs").manifestURL.absoluteString),
        ]
        let later = try DefaultAddon(address: harness.address("anime").manifestURL.absoluteString, round: 2)

        // An app from before the anime catalog was a default.
        let old = harness.registry(defaults: first.map(\.address))
        await old.start()
        #expect(old.addons.map(\.manifest.name) == ["Test Catalog", "Subtitles"])
        // The user has no use for the subtitles add-on.
        await old.uninstall(addonID: old.addons[1].id)

        // The new app: the anime catalog arrives; what was removed stays removed.
        let updated = registry(harness, defaults: first + [later])
        await updated.start()
        #expect(updated.addons.map(\.manifest.name) == ["Test Catalog", "Anime Catalog"])
        #expect(updated.setupError == nil)

        // Removed as well: it is not brought back at the next launch.
        await updated.uninstall(addonID: updated.addons[1].id)
        let relaunched = registry(harness, defaults: first + [later])
        await relaunched.start()
        #expect(relaunched.addons.map(\.manifest.name) == ["Test Catalog"])

        // A profile that has never run gets them all.
        let fresh = try await AddonHarness.make()
        defer { fresh.server.stop() }
        fresh.serveSecondAddon(prefix: "subs", name: "Subtitles")
        fresh.server.respond(to: "/anime/manifest.json", with: .json(animeManifest))
        let everything = try [
            DefaultAddon(address: fresh.address().manifestURL.absoluteString),
            DefaultAddon(address: fresh.address("subs").manifestURL.absoluteString),
            DefaultAddon(address: fresh.address("anime").manifestURL.absoluteString, round: 2),
        ]
        let new = registry(fresh, defaults: everything)
        await new.start()
        #expect(new.addons.map(\.manifest.name) == ["Test Catalog", "Subtitles", "Anime Catalog"])
    }

    @Test("A later default that cannot be reached is tried again at the next launch, without a word")
    func unreachableLaterRound() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        let first = try DefaultAddon(address: harness.address().manifestURL.absoluteString)
        let later = try DefaultAddon(address: harness.address("anime").manifestURL.absoluteString, round: 2)
        let old = harness.registry(defaults: [first.address])
        await old.start()

        let offline = registry(harness, defaults: [first, later])
        await offline.start()
        #expect(offline.addons.map(\.manifest.name) == ["Test Catalog"])
        // The app works without it: nothing to report.
        #expect(offline.setupError == nil && offline.isReady)

        harness.server.respond(to: "/anime/manifest.json", with: .json(animeManifest))
        let online = registry(harness, defaults: [first, later])
        await online.start()
        #expect(online.addons.map(\.manifest.name) == ["Test Catalog", "Anime Catalog"])
    }
}

@Suite("Words on a stream's row")
struct StreamBadgeTests {
    @Test("High dynamic range and overhead sound are read from what the add-on wrote", arguments: [
        ("The.Film.2026.2160p.UHD.BluRay.REMUX.DV.P7.HDR.MULTi.H265", [StreamBadge.dolbyVision, .hdr]),
        ("Film (2160p UHD BluRay x265 10bit DV HDR10+ TrueHD Atmos 7.1)", [.dolbyVision, .hdr, .atmos]),
        ("Film 1080p WEB-DL DDP5.1 Atmos", [.atmos]),
        ("Film.2160p.DoVi.WEB", [.dolbyVision]),
        ("Film 1080p Dolby Vision", [.dolbyVision]),
        // Letters inside other words are not badges.
        ("Advanced.Shdr.Film.1080p.DVDRip", []),
        ("", []),
    ])
    func extras(text: String, expected: [StreamBadge]) {
        #expect(StreamBadge.extras(in: text) == expected)
    }

    @Test("The picture quality comes first")
    func quality() throws {
        let stream = try JSONDecoder().decode(StreamItem.self, from: Data(#"{"url": "https://e.com/a.mkv", "name": "4K HDR", "description": "Atmos"}"#.utf8))
        let choice = StreamChoice(stream: stream, addonID: "a", addonName: "A", position: 0)
        #expect(StreamBadge.badges(for: choice) == [.uhd, .hdr, .atmos])
        #expect(StreamBadge.uhd.isQuality && !StreamBadge.hdr.isQuality)
    }
}
