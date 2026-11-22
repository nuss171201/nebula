import AddonTestSupport
@testable import AppUI
import CoreGraphics
import Foundation
import MediaCore
import MediaLibrary
import Testing

private func title(_ id: String, _ type: MediaType = .movie, backdrop: Bool = true) -> MetaItem {
    MetaItem(id: id, type: type, name: "Title \(id)", background: backdrop ? URL(string: "https://images.example.com/bg/\(id).jpg") : nil)
}

/// A catalog page whose items have backdrops, which the standard fixture's do not.
private func catalogJSON(type: String, ids: [String], withoutBackdrop: Set<String> = []) -> String {
    let items = ids.map { id in
        let backdrop = withoutBackdrop.contains(id) ? "" : #", "background": "https://images.example.com/bg/\#(id).jpg""#
        return #"{"id": "\#(id)", "type": "\#(type)", "name": "Title \#(id)"\#(backdrop)}"#
    }
    return "{\"metas\": [\(items.joined(separator: ","))]}"
}

@Suite("What the Home banner shows")
struct FeaturedPickerTests {
    @Test("Rows take turns, so films and series alternate; six at most")
    func alternates() {
        let films = ["f1", "f2", "f3", "f4"].map { title($0) }
        let series = ["s1", "s2", "s3", "s4"].map { title($0, .series) }
        #expect(FeaturedPicker.picks(from: [films, series]).map(\.id) == ["f1", "s1", "f2", "s2", "f3", "s3"])
        #expect(FeaturedPicker.picks(from: [films, series], limit: 3).map(\.id) == ["f1", "s1", "f2"])
        // A short row runs out and the other carries on.
        #expect(FeaturedPicker.picks(from: [[title("f1")], series]).map(\.id) == ["f1", "s1", "s2", "s3", "s4"])
        #expect(FeaturedPicker.picks(from: []).isEmpty)
        #expect(FeaturedPicker.picks(from: [[], []]).isEmpty)
    }

    @Test("A title without a backdrop is passed over, and a title in both rows is shown once")
    func eligibility() {
        let first = [title("a", backdrop: false), title("b"), title("c")]
        let second = [title("b"), title("d")]
        #expect(FeaturedPicker.picks(from: [first, second]).map(\.id) == ["b", "c", "d"])
        // The same id as a film and as a series is two titles.
        #expect(FeaturedPicker.picks(from: [[title("x")], [title("x", .series)]]).count == 2)
    }

    @Test("The line under the title: rating, year, length, two genres; and how it is read aloud")
    func words() {
        let item = MetaItem(
            id: "tt1", type: .movie, name: "Example", releaseInfo: "2026", imdbRating: 8.44,
            runtime: "173 min", genres: ["Action", "Adventure", "Drama"]
        )
        #expect(FeaturedModel.facts(for: item) == ["★ 8.4", "2026", "173 min", "Action, Adventure"])
        #expect(FeaturedModel.spokenSummary(for: item) == "Example, rated 8.4, 2026, 173 min, Action, Adventure")
        #expect(FeaturedModel.facts(for: MetaItem(id: "tt2", type: .series, name: "Bare")).isEmpty)
    }

    @Test("The banner turns by itself only in the window in use, unpointed at, for people who have not asked otherwise")
    func turning() {
        func turns(count: Int = 6, pointed: Bool = false, lessMotion: Bool = false, readAloud: Bool = false, key: Bool = true) -> Bool {
            FeaturedModel.turnsByItself(count: count, isPointedAt: pointed, reducesMotion: lessMotion, isReadAloud: readAloud, isInKeyWindow: key)
        }
        #expect(turns())
        #expect(!turns(count: 1))
        #expect(!turns(pointed: true))
        #expect(!turns(lessMotion: true))
        #expect(!turns(readAloud: true))
        // Behind the player's window, say, while a film plays.
        #expect(!turns(key: false))
    }
}

@Suite("Whether a logo can be read on the banner")
struct LogoLegibilityTests {
    /// A logo-shaped picture: a band of one colour across a transparent canvas.
    private func logo(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 320, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: blue, alpha: alpha)
        context.fill(CGRect(x: 20, y: 35, width: 280, height: 30))
        return try #require(context.makeImage())
    }

    @Test("Light logos are shown; one drawn for a light page gives way to words; an empty one too")
    func brightness() throws {
        let white = try #require(LogoLegibility.brightness(of: logo(red: 1, green: 1, blue: 1)))
        #expect(white > 0.95)
        #expect(try LogoLegibility.isReadableOnDark(logo(red: 1, green: 1, blue: 1)))
        #expect(try LogoLegibility.isReadableOnDark(logo(red: 0.95, green: 0.75, blue: 0.2)))

        // The slate blue of a logo that could not be read where the banner had put it.
        let slate = try #require(LogoLegibility.brightness(of: logo(red: 0.25, green: 0.33, blue: 0.5)))
        #expect(slate < 0.4)
        #expect(try !LogoLegibility.isReadableOnDark(logo(red: 0.25, green: 0.33, blue: 0.5)))
        #expect(try !LogoLegibility.isReadableOnDark(logo(red: 0, green: 0, blue: 0)))

        #expect(try LogoLegibility.brightness(of: logo(red: 1, green: 1, blue: 1, alpha: 0)) == nil)
        #expect(try !LogoLegibility.isReadableOnDark(logo(red: 1, green: 1, blue: 1, alpha: 0)))
    }
}

@MainActor
@Suite("The Home banner's model")
struct FeaturedModelTests {
    @Test("Moves on and back around the ends, and shows a chosen title")
    func moving() {
        let model = FeaturedModel()
        model.advance()
        #expect(model.current == nil && model.next == nil)
        model.update(["a", "b", "c"].map { title($0) })
        #expect(model.current?.id == "a" && model.next?.id == "b")
        model.advance()
        model.advance()
        #expect(model.current?.id == "c" && model.next?.id == "a")
        model.advance()
        #expect(model.index == 0)
        model.goBack()
        #expect(model.current?.id == "c")
        model.show(1)
        #expect(model.current?.id == "b")
        model.show(9)
        #expect(model.current?.id == "b")
        // One title has nowhere to go.
        model.update([title("only")])
        model.advance()
        model.goBack()
        #expect(model.index == 0 && model.next == nil)
    }

    @Test("When the titles change, the one on show stays on show if it is still among them")
    func keepsItsPlace() {
        let model = FeaturedModel()
        model.update(["a", "b", "c"].map { title($0) })
        model.show(2)
        // A second row has answered and its titles are woven in.
        model.update(["a", "x", "b", "y", "c", "z"].map { title($0) })
        #expect(model.current?.id == "c" && model.index == 4)
        model.update(["x", "y"].map { title($0) })
        #expect(model.index == 0 && model.current?.id == "x")
    }

    @Test("Saving from the banner puts the title in the library, and taking it out removes it")
    func library() async throws {
        let database = try LibraryDatabase.inMemory()
        let center = LibraryCenter(library: LibraryStore(database: database), history: WatchHistoryStore(database: database), logSubsystem: "test.appui")
        let model = FeaturedModel()
        let item = title("tt7", .series)
        model.update([title("tt1"), item])
        await model.refreshSaved(from: center)
        #expect(!model.isSaved(item))

        await model.toggleSaved(item, in: center)
        #expect(model.isSaved(item) && !model.isSaved(title("tt1")))
        #expect(await center.isSaved(type: .series, id: "tt7"))
        #expect(await center.items().map(\.name) == ["Title tt7"])

        await model.toggleSaved(item, in: center)
        #expect(!model.isSaved(item))
        #expect(await !center.isSaved(type: .series, id: "tt7"))
    }
}

@MainActor
@Suite("The banner and the Home board")
struct HomeFeaturedTests {
    @Test("The banner is filled from the first two rows, loaded whether or not they are in view")
    func fromTheFirstRows() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        harness.server.respond(to: "/catalog/movie/top.json", with: .json(catalogJSON(type: "movie", ids: ["f1", "f2", "f3"], withoutBackdrop: ["f2"])))
        harness.server.respond(to: "/catalog/series/top.json", with: .json(catalogJSON(type: "series", ids: ["s1", "s2"])))
        let model = HomeModel(client: harness.client)
        try await model.update(addons: [harness.installedAddon()])
        // Nothing has answered: the banner's place is kept.
        #expect(model.featured.items.isEmpty && model.isFeaturedPending)

        await model.rows[0].loadIfNeeded()
        #expect(model.featured.items.map(\.id) == ["f1", "f3"])
        #expect(model.isFeaturedPending)

        await model.loadFeaturedRows()
        #expect(model.featured.items.map(\.id) == ["f1", "s1", "f3", "s2"])
        #expect(!model.isFeaturedPending)
        #expect(harness.server.requestCount(for: "/catalog/movie/top.json") == 1)

        // The add-on is disabled: its rows go, and so does what the banner took from them.
        model.update(addons: [])
        #expect(model.featured.items.isEmpty && !model.isFeaturedPending)
    }

    @Test("Rows that fail or have no backdrops leave no banner, and its place is given up")
    func nothingToShow() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        harness.server.respond(to: "/catalog/movie/top.json", with: .status(500))
        harness.server.respond(to: "/catalog/series/top.json", with: .json(AddonFixtures.catalogJSON(type: "series", count: 3)))
        let model = HomeModel(client: harness.client)
        try await model.update(addons: [harness.installedAddon()])
        await model.loadFeaturedRows()
        #expect(model.featured.items.isEmpty)
        #expect(!model.isFeaturedPending)
    }
}

@Suite("Where Play starts a series")
struct EpisodeToStartTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func episode(_ season: Int, _ number: Int, airedDaysAgo days: Double? = 30) -> MetaVideo {
        MetaVideo(id: "tt42:\(season):\(number)", title: "Episode \(number)", released: days.map { now - $0 * 86400 }, season: season, episode: number)
    }

    private func entry(_ season: Int, _ number: Int, watched: Bool, minutesAgo: Double) -> (String, WatchEntry) {
        let video = WatchVideo(type: .series, videoID: "tt42:\(season):\(number)", titleID: "tt42", titleName: "Show", season: season, episode: number)
        return (video.videoID, WatchEntry(video: video, position: watched ? 0 : 300, duration: 1500, isWatched: watched, lastWatchedAt: now - minutesAgo * 60))
    }

    private var episodes: [MetaVideo] {
        [episode(0, 1), episode(2, 1), episode(1, 2), episode(1, 1), episode(2, 2, airedDaysAgo: -7)]
    }

    @Test("A series never started begins at the first episode that has aired; specials do not count")
    func neverStarted() {
        #expect(DetailModel.episodeToStart(in: episodes, entries: [:], now: now)?.id == "tt42:1:1")
        let upcoming = [episode(1, 1, airedDaysAgo: -3), episode(1, 2, airedDaysAgo: -1)]
        #expect(DetailModel.episodeToStart(in: upcoming, entries: [:], now: now) == nil)
        #expect(DetailModel.episodeToStart(in: [episode(0, 1)], entries: [:], now: now) == nil)
        #expect(DetailModel.episodeToStart(in: [], entries: [:], now: now) == nil)
    }

    @Test("A series in progress carries on: the unfinished episode, or the one after the last finished")
    func inProgress() {
        let unfinished = Dictionary(uniqueKeysWithValues: [entry(1, 1, watched: true, minutesAgo: 90), entry(1, 2, watched: false, minutesAgo: 5)])
        #expect(DetailModel.episodeToStart(in: episodes, entries: unfinished, now: now)?.id == "tt42:1:2")
        let finished = Dictionary(uniqueKeysWithValues: [entry(1, 1, watched: true, minutesAgo: 90), entry(1, 2, watched: true, minutesAgo: 5)])
        #expect(DetailModel.episodeToStart(in: episodes, entries: finished, now: now)?.id == "tt42:2:1")
        // It is the most recently watched that counts, not the furthest on.
        let wentBack = Dictionary(uniqueKeysWithValues: [entry(2, 1, watched: true, minutesAgo: 900), entry(1, 1, watched: true, minutesAgo: 5)])
        #expect(DetailModel.episodeToStart(in: episodes, entries: wentBack, now: now)?.id == "tt42:1:2")
    }

    @Test("With nothing aired after the last one watched, Play starts the series again")
    func caughtUp() {
        let all = Dictionary(uniqueKeysWithValues: [entry(2, 1, watched: true, minutesAgo: 5)])
        // Season 2 episode 2 has not aired.
        #expect(DetailModel.episodeToStart(in: episodes, entries: all, now: now)?.id == "tt42:1:1")
    }
}

@MainActor
@Suite("A page opened to play")
struct PlayWhenReadyTests {
    private static let streamManifest = """
    {"id": "test.streams", "version": "1.0.0", "name": "Test Streams", "resources": ["stream"],
     "types": ["movie", "series"], "idPrefixes": ["tt"]}
    """

    private func makeApp() -> AppModel {
        AppModel(dependencies: .ephemeral(http: StubHTTPClient(data: Data())), reportMilestone: { _ in nil })
    }

    private func addons(_ harness: AddonHarness, withStreams: Bool = true) async throws -> [InstalledAddon] {
        guard withStreams else { return try await [harness.installedAddon()] }
        harness.server.respond(to: "/streams/manifest.json", with: .json(Self.streamManifest))
        let address = try harness.address("streams")
        return try await [harness.installedAddon(), InstalledAddon(address: address, manifest: harness.client.manifest(at: address))]
    }

    @Test("Play on the banner opens the title's page, and that page (once) is the one that plays")
    func opensToPlay() {
        let app = makeApp()
        let item = title("tt0000001")
        app.play(item)
        #expect(app.path == [MediaRoute(item: item)])
        // The page builds its model more than once; only the first is kept, and only it plays.
        #expect(app.detailModel(for: app.path[0]).startsPlaying)
        #expect(!app.detailModel(for: app.path[0]).startsPlaying)
        // A page opened by a click on a poster does not play by itself.
        #expect(!app.detailModel(for: MediaRoute(item: title("tt0000002"))).startsPlaying)
    }

    @Test("A film plays as soon as its streams are in; a page opened any other way is left alone")
    func film() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        harness.server.respond(to: "/meta/movie/tt0000001.json", with: .json(AddonFixtures.movieMetaJSON()))
        harness.server.respond(
            to: "/streams/stream/movie/tt0000001.json",
            with: .json(#"{"streams": [{"url": "https://cdn.example.com/film.mp4", "name": "1080p"}]}"#)
        )
        let app = makeApp()
        let detail = DetailModel(route: MediaRoute(type: .movie, id: "tt0000001"), client: harness.client)
        var pressed: [String] = []
        let press: @MainActor (DetailModel) -> Void = { pressed.append($0.streams.picks.first?.choice.title ?? "nothing") }

        // Not opened to play.
        try await detail.load(addons: addons(harness))
        #expect(await !app.playWhenReady(detail, pollingEvery: .milliseconds(5), press: press))
        #expect(pressed.isEmpty)

        detail.startsPlaying = true
        #expect(await app.playWhenReady(detail, pollingEvery: .milliseconds(5), press: press))
        #expect(pressed == ["1080p"])
        // Once only: coming back to the page does not start the film again.
        #expect(await !app.playWhenReady(detail, pollingEvery: .milliseconds(5), press: press))
        #expect(pressed.count == 1)
    }

    @Test("A series opens on the episode to carry on with, and plays it")
    func series() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        harness.server.respond(to: "/meta/series/tt0000042.json", with: .json(AddonFixtures.seriesMetaJSON()))
        harness.server.respond(
            to: "/streams/stream/series/tt0000042%3A1%3A1.json",
            with: .json(#"{"streams": [{"url": "https://cdn.example.com/s1e1.mp4", "name": "720p"}]}"#)
        )
        let app = makeApp()
        let detail = DetailModel(route: MediaRoute(type: .series, id: "tt0000042"), client: harness.client)
        detail.startsPlaying = true
        try await detail.load(addons: addons(harness))
        #expect(detail.selectedSeason == 1 && detail.selectedVideoID == "tt0000042:1:1")

        var pressed: [String?] = []
        #expect(await app.playWhenReady(detail, pollingEvery: .milliseconds(5)) { pressed.append($0.streamVideo?.videoID) })
        #expect(pressed == ["tt0000042:1:1"])
    }

    @Test("With no add-on that offers streams, or none for this title, the page just opens")
    func nothingToPlay() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        harness.server.respond(to: "/meta/movie/tt0000001.json", with: .json(AddonFixtures.movieMetaJSON()))
        harness.server.respond(to: "/streams/stream/movie/tt0000001.json", with: .json(#"{"streams": []}"#))
        let app = makeApp()
        var presses = 0

        let withoutProvider = DetailModel(route: MediaRoute(type: .movie, id: "tt0000001"), client: harness.client)
        withoutProvider.startsPlaying = true
        try await withoutProvider.load(addons: addons(harness, withStreams: false))
        #expect(await !app.playWhenReady(withoutProvider, pollingEvery: .milliseconds(5)) { _ in presses += 1 })

        let withoutStreams = DetailModel(route: MediaRoute(type: .movie, id: "tt0000001"), client: harness.client)
        withoutStreams.startsPlaying = true
        try await withoutStreams.load(addons: addons(harness))
        #expect(await !app.playWhenReady(withoutStreams, pollingEvery: .milliseconds(5)) { _ in presses += 1 })

        // A page that could not be loaded at all.
        let missing = DetailModel(route: MediaRoute(type: .movie, id: "tt0000009"), client: harness.client)
        missing.startsPlaying = true
        try await missing.load(addons: addons(harness))
        #expect(await !app.playWhenReady(missing, pollingEvery: .milliseconds(5)) { _ in presses += 1 })
        #expect(presses == 0)
    }
}
