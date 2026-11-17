import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import Testing

@MainActor
@Suite("Search")
struct SearchModelTests {
    private func makeModel(_ harness: AddonHarness, addons: [InstalledAddon]) -> SearchModel {
        let model = SearchModel(client: harness.client, debounce: .milliseconds(40))
        model.update(addons: addons)
        return model
    }

    @Test("Typing is debounced: only the final query is sent")
    func debounce() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(
            to: "/catalog/movie/top/search=dune.json",
            with: .json(AddonFixtures.catalogJSON(titlePrefix: "Dune", count: 2))
        )
        harness.server.respond(to: "/catalog/series/top/search=dune.json", with: .json(AddonFixtures.catalogJSON(count: 0)))
        let model = try await makeModel(harness, addons: [harness.installedAddon()])
        #expect(model.hasSearchableAddons)

        for partial in ["d", "du", "dun", "  dune "] {
            model.query = partial
        }
        #expect(model.isActive)
        #expect(model.phase == .searching)
        await model.waitForSearch()

        #expect(model.phase == .finished)
        let searches = harness.server.requestedTargets.filter { $0.contains("search=") }
        #expect(searches.sorted() == ["/catalog/movie/top/search=dune.json", "/catalog/series/top/search=dune.json"])
        #expect(model.sections.count == 1)
        #expect(model.sections[0].addonName == "Test Catalog")
        #expect(model.sections[0].rows.map(\.title) == ["Movies"])
        #expect(model.sections[0].rows[0].items.map(\.name) == ["Dune 1", "Dune 2"])
    }

    @Test("Results are grouped by add-on, in install order, with one row per type")
    func grouping() async throws {
        let harness = try await AddonHarness.make()
        harness.serveSecondAddon(prefix: "two", name: "Second")
        for (path, prefix) in [("", "A"), ("/two", "B")] {
            harness.server.respond(
                to: "\(path)/catalog/movie/top/search=x.json",
                with: .json(AddonFixtures.catalogJSON(titlePrefix: "\(prefix) Movie", count: 1))
            )
            harness.server.respond(
                to: "\(path)/catalog/series/top/search=x.json",
                with: .json(AddonFixtures.catalogJSON(type: "series", titlePrefix: "\(prefix) Show", count: 1))
            )
        }
        let second = try await InstalledAddon(
            address: harness.address("two"),
            manifest: harness.client.manifest(at: harness.address("two"))
        )
        let model = try await makeModel(harness, addons: [harness.installedAddon(), second])

        model.query = "x"
        await model.waitForSearch()
        #expect(model.sections.map(\.addonName) == ["Test Catalog", "Second"])
        #expect(model.sections.map { $0.rows.map(\.title) } == [["Movies", "Series"], ["Movies", "Series"]])
        #expect(model.sections[1].rows[1].items.first?.name == "B Show 1")
        #expect(model.failedAddonNames.isEmpty)
    }

    @Test("An add-on that fails is named, and the others still show results")
    func partialFailure() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(
            to: "/catalog/movie/top/search=x.json",
            with: .json(AddonFixtures.catalogJSON(count: 1))
        )
        harness.server.respond(to: "/catalog/series/top/search=x.json", with: .status(500))
        let model = try await makeModel(harness, addons: [harness.installedAddon()])

        model.query = "x"
        await model.waitForSearch()
        #expect(model.sections.count == 1)
        #expect(model.failedAddonNames == ["Test Catalog"])
    }

    @Test("Clearing the query clears the results")
    func clearing() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/catalog/movie/top/search=x.json", with: .json(AddonFixtures.catalogJSON(count: 1)))
        let model = try await makeModel(harness, addons: [harness.installedAddon()])
        model.query = "x"
        await model.waitForSearch()
        #expect(!model.sections.isEmpty)

        model.query = "   "
        #expect(!model.isActive)
        #expect(model.phase == .idle)
        #expect(model.sections.isEmpty)
    }
}

@MainActor
@Suite("Detail page")
struct DetailModelTests {
    @Test("Shows the preview at once, then seasons and episodes in order")
    func series() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/meta/series/tt0000042.json", with: .json(AddonFixtures.seriesMetaJSON()))
        let preview = MetaItem(id: "tt0000042", type: .series, name: "Preview name")
        let model = DetailModel(route: MediaRoute(item: preview), client: harness.client)
        #expect(model.title == "Preview name")
        #expect(model.phase == .loading)

        try await model.load(addons: [harness.installedAddon()])
        #expect(model.phase == .loaded)
        #expect(model.title == "Example Show")
        #expect(model.seasons == [1, 2, 0])
        #expect(model.selectedSeason == 1)
        #expect(model.episodes.map(\.numberedTitle) == ["1. Pilot", "2. Second"])
        #expect(model.trailer?.youTubeID == "abcdefghijk")
        #expect(model.looseVideos.isEmpty)

        model.selectedSeason = 0
        #expect(model.episodes.map(\.title) == ["Behind the Scenes"])
        #expect(DetailModel.seasonTitle(0) == "Specials")
        #expect(DetailModel.seasonTitle(3) == "Season 3")
    }

    @Test("Falls back to the next add-on when the first has nothing")
    func fallback() async throws {
        let harness = try await AddonHarness.make()
        harness.serveSecondAddon(prefix: "two", name: "Second")
        harness.server.respond(to: "/two/meta/movie/tt0000001.json", with: .json(AddonFixtures.movieMetaJSON()))
        let first = try await harness.installedAddon()
        let second = try await InstalledAddon(
            address: harness.address("two"),
            manifest: harness.client.manifest(at: harness.address("two"))
        )

        let model = DetailModel(route: MediaRoute(type: .movie, id: "tt0000001"), client: harness.client)
        await model.load(addons: [first, second])
        #expect(model.phase == .loaded)
        #expect(model.meta?.name == "Example Movie")
        #expect(model.meta?.factLine == ["2001", "118 min", "★ 7.4"])
        #expect(model.seasons.isEmpty)
        #expect(harness.server.requestCount(for: "/meta/movie/tt0000001.json") == 1)
    }

    @Test("Explains when no add-on can provide details")
    func noProvider() async throws {
        let harness = try await AddonHarness.make()
        let addon = try await harness.installedAddon()

        let unsupported = DetailModel(route: MediaRoute(type: .movie, id: "kitsu:1"), client: harness.client)
        await unsupported.load(addons: [addon])
        #expect(unsupported.phase == .failed("None of your add-ons provides details for this title."))

        let missing = DetailModel(route: MediaRoute(type: .movie, id: "tt404"), client: harness.client)
        await missing.load(addons: [addon])
        #expect(missing.phase == .failed("The add-on has no information for this title."))
    }
}

@MainActor
@Suite("Add-ons screen")
struct AddonsModelTests {
    @Test("Installing is two steps: fetch and show, then confirm")
    func installFlow() async throws {
        let harness = try await AddonHarness.make()
        let registry = harness.registry()
        await registry.start()
        let model = AddonsModel(registry: registry)
        #expect(!model.canSubmitAddress)

        model.addressInput = harness.baseURL.absoluteString
        #expect(model.canSubmitAddress)
        await model.fetchPendingInstall()
        #expect(model.pendingInstall?.manifest.name == "Test Catalog")
        #expect(registry.addons.isEmpty)

        await model.confirmInstall()
        #expect(model.pendingInstall == nil)
        #expect(model.addressInput.isEmpty)
        #expect(registry.addons.count == 1)
    }

    @Test("Cancelling installs nothing, and errors are shown in plain words")
    func cancelAndErrors() async throws {
        let harness = try await AddonHarness.make()
        let registry = harness.registry()
        await registry.start()
        let model = AddonsModel(registry: registry)

        model.addressInput = harness.baseURL.absoluteString
        await model.fetchPendingInstall()
        model.cancelInstall()
        #expect(registry.addons.isEmpty)

        model.addressInput = "ftp://example.com"
        await model.fetchPendingInstall()
        #expect(model.installPhase == .failed("That does not look like an add-on address."))
        model.clearInstallError()
        #expect(model.installPhase == .idle)

        model.addressInput = harness.baseURL.absoluteString + "missing"
        await model.fetchPendingInstall()
        #expect(model.installPhase == .failed("Could not load the add-on. The server returned an error (404)."))
    }

    @Test("Summarises what an add-on provides")
    func summary() {
        let manifest = AddonManifest(
            id: "x",
            name: "X",
            types: [.series, .movie],
            resources: [ManifestResource(name: "catalog"), ManifestResource(name: "meta"), ManifestResource(name: "subtitles")]
        )
        #expect(AddonsModel.summary(of: manifest) == "Catalogs, metadata, subtitles · Movies, Series")
        #expect(AddonsModel.summary(of: AddonManifest(id: "y", name: "Y")).isEmpty)
    }
}
