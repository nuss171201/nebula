import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import Testing

@MainActor
@Suite("Home board")
struct HomeModelTests {
    @Test("Shows only catalogs that need no filter, and loads a row on demand")
    func rows() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/catalog/movie/top.json", with: .json(AddonFixtures.catalogJSON(count: 5)))
        let model = HomeModel(client: harness.client)
        try await model.update(addons: [harness.installedAddon()])

        #expect(model.rows.map(\.title) == ["Popular · Movies", "Popular · Series"])
        #expect(model.rows.allSatisfy { $0.addonName == "Test Catalog" })

        let row = model.rows[0]
        #expect(row.state == .idle)
        await row.loadIfNeeded()
        #expect(row.state.value?.count == 5)
        #expect(!row.isEmpty)

        await row.loadIfNeeded()
        #expect(harness.server.requestCount(for: "/catalog/movie/top.json") == 1)
    }

    @Test("A failed row explains itself and can be retried")
    func failureAndRetry() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(
            to: "/catalog/movie/top.json",
            with: .status(500), .json(AddonFixtures.catalogJSON(count: 2))
        )
        let model = HomeModel(client: harness.client)
        try await model.update(addons: [harness.installedAddon()])
        let row = model.rows[0]

        await row.loadIfNeeded()
        #expect(row.state.errorMessage == "The server returned an error (500).")
        await row.retry()
        #expect(row.state.value?.count == 2)
    }

    @Test("Updating add-ons keeps loaded rows and drops rows of disabled add-ons")
    func update() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/catalog/movie/top.json", with: .json(AddonFixtures.catalogJSON(count: 3)))
        var addon = try await harness.installedAddon()
        let model = HomeModel(client: harness.client)
        model.update(addons: [addon])
        await model.rows[0].loadIfNeeded()
        let loadedRow = model.rows[0]

        model.update(addons: [addon])
        #expect(model.rows[0] === loadedRow)

        addon.isEnabled = false
        model.update(addons: [addon])
        #expect(model.rows.isEmpty)
    }
}

@MainActor
@Suite("Discover")
struct DiscoverModelTests {
    private func makeModel(_ harness: AddonHarness) async throws -> DiscoverModel {
        let model = DiscoverModel(client: harness.client)
        try await model.update(addons: [harness.installedAddon()])
        return model
    }

    @Test("Starts on the first type and catalog and loads its first page")
    func initialLoad() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/catalog/movie/top.json", with: .json(AddonFixtures.catalogJSON(count: 30, hasMore: true)))
        let model = try await makeModel(harness)

        #expect(model.types == [.movie, .series])
        #expect(model.selectedType == .movie)
        #expect(model.catalogs.map(\.catalog.id) == ["top", "year"])
        #expect(model.selectedCatalog?.catalog.id == "top")
        #expect(model.filters.map(\.title) == ["Genre"])
        #expect(model.filters[0].selection == nil)
        #expect(model.phase == .loadingFirstPage)

        await model.waitForLoading()
        #expect(model.phase == .loaded)
        #expect(model.items.count == 30)
        #expect(model.canLoadMore)
    }

    @Test("Choosing a filter reloads with it in the request; clearing it goes back")
    func filters() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/catalog/movie/top.json", with: .json(AddonFixtures.catalogJSON(count: 4)))
        harness.server.respond(
            to: "/catalog/movie/top/genre=Sci-Fi.json",
            with: .json(AddonFixtures.catalogJSON(titlePrefix: "SciFi", count: 2))
        )
        let model = try await makeModel(harness)
        await model.waitForLoading()

        model.setFilter("genre", to: "Sci-Fi")
        #expect(model.items.isEmpty)
        await model.waitForLoading()
        #expect(model.items.map(\.name) == ["SciFi 1", "SciFi 2"])

        model.setFilter("genre", to: "Not an option")
        #expect(model.filters[0].selection == "Sci-Fi")

        model.setFilter("genre", to: nil)
        await model.waitForLoading()
        #expect(model.items.count == 4)
    }

    @Test("A catalog with a required filter starts on its first option, shown as Year")
    func requiredFilter() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/catalog/movie/top.json", with: .json(AddonFixtures.catalogJSON(count: 1)))
        harness.server.respond(
            to: "/catalog/movie/year/genre=2026.json",
            with: .json(AddonFixtures.catalogJSON(titlePrefix: "New", count: 3))
        )
        let model = try await makeModel(harness)
        let yearCatalog = try #require(model.catalogs.last)

        model.select(catalogID: yearCatalog.id)
        #expect(model.filters.map(\.title) == ["Year"])
        #expect(model.filters[0].selection == "2026")
        await model.waitForLoading()
        #expect(model.items.map(\.name) == ["New 1", "New 2", "New 3"])

        model.setFilter("genre", to: nil)
        #expect(model.filters[0].selection == "2026")
    }

    @Test("Scrolling near the end loads the next page and stops when nothing new arrives")
    func paging() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/catalog/movie/top.json", with: .json(AddonFixtures.catalogJSON(count: 20)))
        harness.server.respond(
            to: "/catalog/movie/top/skip=20.json",
            with: .json(AddonFixtures.catalogJSON(count: 20, offset: 15))
        )
        harness.server.respond(to: "/catalog/movie/top/skip=35.json", with: .json(AddonFixtures.catalogJSON(count: 0)))
        let model = try await makeModel(harness)
        await model.waitForLoading()

        model.itemDidAppear(model.items[2])
        #expect(model.phase == .loaded)

        model.itemDidAppear(model.items[19])
        #expect(model.phase == .loadingMore)
        await model.waitForLoading()
        // Five of the second page's items were already shown and must not repeat.
        #expect(model.items.count == 35)
        #expect(Set(model.items.map(\.id)).count == 35)
        #expect(model.canLoadMore)

        model.itemDidAppear(model.items[34])
        await model.waitForLoading()
        #expect(model.items.count == 35)
        #expect(!model.canLoadMore)
    }

    @Test("Switching type discards the slower earlier request")
    func staleResponses() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(
            to: "/catalog/movie/top.json",
            with: .json(AddonFixtures.catalogJSON(count: 5), delay: .milliseconds(300))
        )
        harness.server.respond(
            to: "/catalog/series/top.json",
            with: .json(AddonFixtures.catalogJSON(type: "series", titlePrefix: "Show", count: 2))
        )
        let model = try await makeModel(harness)

        model.select(type: .series)
        await model.waitForLoading()
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.selectedType == .series)
        #expect(model.catalogs.map(\.catalog.id) == ["top"])
        #expect(model.items.map(\.name) == ["Show 1", "Show 2"])
    }

    @Test("A failed load can be retried")
    func failure() async throws {
        let harness = try await AddonHarness.make()
        harness.server.respond(
            to: "/catalog/movie/top.json",
            with: .status(503), .json(AddonFixtures.catalogJSON(count: 2))
        )
        let model = try await makeModel(harness)
        await model.waitForLoading()
        #expect(model.phase == .failed("The server returned an error (503)."))

        model.retry()
        await model.waitForLoading()
        #expect(model.phase == .loaded)
        #expect(model.items.count == 2)
    }

    @Test("With no add-ons there is nothing to browse")
    func empty() {
        let model = DiscoverModel(client: AddonClient(http: StubHTTPClient(data: Data())))
        model.update(addons: [])
        #expect(!model.hasCatalogs)
        #expect(model.phase == .idle)
        #expect(model.types.isEmpty)
    }
}
