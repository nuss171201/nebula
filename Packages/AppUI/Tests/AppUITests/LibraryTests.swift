import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary
import PlayerKit
import StreamEngine
import Testing

private func episode(_ season: Int, _ number: Int, released: Date? = Date(timeIntervalSince1970: 1_000_000)) -> MetaVideo {
    MetaVideo(id: "tt42:\(season):\(number)", title: "Episode \(number)", released: released, season: season, episode: number)
}

private func watched(_ season: Int, _ number: Int) -> WatchVideo {
    WatchVideo(type: .series, videoID: "tt42:\(season):\(number)", titleID: "tt42", titleName: "Example Show", season: season, episode: number)
}

@Suite("Continue Watching (pure)")
struct ContinueWatchingRuleTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private var videos: [MetaVideo] {
        [
            episode(0, 1), episode(1, 1), episode(1, 2), episode(1, 3), episode(2, 1),
            episode(2, 2, released: Date(timeIntervalSince1970: 3_000_000)), episode(2, 3, released: nil),
        ]
    }

    @Test("The next episode is the following one in the season, then the first of the next season")
    func nextEpisode() {
        #expect(ContinueWatching.nextEpisode(after: watched(1, 1), in: videos, now: now)?.id == "tt42:1:2")
        #expect(ContinueWatching.nextEpisode(after: watched(1, 3), in: videos, now: now)?.id == "tt42:2:1")
        // Given out of order, the answer is the same.
        #expect(ContinueWatching.nextEpisode(after: watched(1, 1), in: videos.reversed(), now: now)?.id == "tt42:1:2")
    }

    @Test("An episode that has not aired is not next, nor is anything after it; specials are never next")
    func limits() {
        #expect(ContinueWatching.nextEpisode(after: watched(2, 1), in: videos, now: now) == nil)
        #expect(ContinueWatching.nextEpisode(after: watched(2, 3), in: videos, now: now) == nil)
        // Once it has aired, it is.
        #expect(ContinueWatching.nextEpisode(after: watched(2, 1), in: videos, now: Date(timeIntervalSince1970: 4_000_000))?.id == "tt42:2:2")
        #expect(ContinueWatching.nextEpisode(after: watched(0, 1), in: videos, now: now) == nil)
        let film = WatchVideo(type: .movie, videoID: "tt1", titleID: "tt1", titleName: "Film")
        #expect(ContinueWatching.nextEpisode(after: film, in: videos, now: now) == nil)
    }

    @Test("An unfinished video is resumed; a finished episode leads to the next; a finished film to nothing")
    func items() throws {
        let unfinished = WatchEntry(video: watched(1, 2), position: 600, duration: 1500, isWatched: false, lastWatchedAt: now)
        let resume = try #require(ContinueWatching.item(for: unfinished, videos: nil, now: now))
        #expect(resume.kind == .resume && resume.progress == 0.4 && resume.remaining == 900)
        #expect(resume.statusLine == "15 min left")
        #expect(resume.episodeLine == "S1 · E2")

        let finished = WatchEntry(video: watched(1, 3), position: 0, duration: 1500, isWatched: true, lastWatchedAt: now)
        // Without the episode list there is nothing to offer yet.
        #expect(ContinueWatching.item(for: finished, videos: nil, now: now) == nil)
        let next = try #require(ContinueWatching.item(for: finished, videos: videos, now: now))
        #expect(next.kind == .nextEpisode && next.video.videoID == "tt42:2:1")
        #expect(next.video.season == 2 && next.video.episode == 1 && next.video.videoTitle == "Episode 1")
        #expect(next.statusLine == "Next episode" && next.episodeLine == "S2 · E1 — Episode 1")
        #expect(next.id == resume.id)

        let film = WatchVideo(type: .movie, videoID: "tt1", titleID: "tt1", titleName: "Film")
        #expect(ContinueWatching.item(for: WatchEntry(video: film, position: 0, duration: 100, isWatched: true, lastWatchedAt: now), videos: nil) == nil)
        // Opened but never really begun.
        #expect(ContinueWatching.item(for: WatchEntry(video: film, position: 0, duration: nil, isWatched: false, lastWatchedAt: now), videos: nil) == nil)
    }

    @Test("What is left is said in minutes and hours", arguments: [
        (30.0, "Less than a minute left"), (90.0, "2 min left"), (3540.0, "59 min left"), (5400.0, "1 h 30 min left"),
    ])
    func remaining(seconds: Double, expected: String) {
        let item = ContinueItem(video: watched(1, 1), kind: .resume, progress: 0.5, remaining: seconds)
        #expect(item.statusLine == expected)
    }

    @Test("Without a known length a resume card just says so; specials and films read naturally")
    func lines() {
        #expect(ContinueItem(video: watched(1, 1), kind: .resume).statusLine == "Resume")
        var special = watched(0, 2)
        special.videoTitle = "Behind the Scenes"
        #expect(ContinueItem(video: special, kind: .resume).episodeLine == "Special 2 — Behind the Scenes")
        let film = WatchVideo(type: .movie, videoID: "tt1", titleID: "tt1", titleName: "Film")
        #expect(ContinueItem(video: film, kind: .resume).episodeLine == nil)
    }

    @Test("The player's names for catalog videos are read back, colons in the id included")
    func watchKeys() throws {
        let key = WatchKey.make(type: .series, videoID: "tt42:1:2")
        #expect(key == "video:series:tt42:1:2")
        let parsed = try #require(WatchKey.parse(key))
        #expect(parsed.type == .series && parsed.videoID == "tt42:1:2")
        #expect(WatchKey.parse("file:/films/a.mkv") == nil)
        #expect(WatchKey.parse("video:movie:") == nil)
        #expect(WatchKey.parse("title:movie:tt1") == nil)
    }
}

@MainActor
@Suite("Library, history and Continue Watching models")
struct LibraryModelTests {
    private struct Fixture {
        let harness: AddonHarness
        let center: LibraryCenter
        let history: WatchHistoryStore
    }

    private func makeFixture() async throws -> Fixture {
        let harness = try await AddonHarness.make()
        let history = WatchHistoryStore(database: harness.database)
        return Fixture(
            harness: harness,
            center: LibraryCenter(library: LibraryStore(database: harness.database), history: history),
            history: history
        )
    }

    @Test("Every change moves the revision, so that screens know to look again")
    func revision() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        let center = fixture.center
        #expect(center.revision == 0)
        await center.save(MetaItem(id: "tt1", type: .movie, name: "Film"))
        #expect(center.revision == 1)
        #expect(await center.isSaved(type: .movie, id: "tt1"))
        await center.remove(type: .movie, id: "tt1")
        await center.begin(watched(1, 1))
        await center.setWatched(true, videos: [watched(1, 1)])
        center.noteChange()
        #expect(center.revision == 5)
        #expect(await !center.isSaved(type: .movie, id: "tt1"))
        #expect(await center.entries(type: .series, titleID: "tt42")["tt42:1:1"]?.isWatched == true)
    }

    @Test("The Library screen lists saved titles by type and order, and the history")
    func libraryScreen() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        let center = fixture.center
        await center.save(MetaItem(id: "tt1", type: .movie, name: "Beta Film", releaseInfo: "2001"))
        await center.save(MetaItem(id: "tt2", type: .series, name: "Alpha Show", posterShape: .landscape))
        await center.begin(watched(1, 1))
        try await fixture.history.record(.at(300), duration: 1200, type: .series, videoID: "tt42:1:1")

        let model = LibraryModel(library: center)
        await model.reload()
        #expect(model.hasLoaded)
        #expect(Set(model.items.map(\.name)) == ["Beta Film", "Alpha Show"])
        #expect(model.availableTypes == [.movie, .series])
        #expect(model.history.map(\.video.videoID) == ["tt42:1:1"])
        // Saved titles become ordinary catalog items again for the poster cards.
        let show = try #require(model.items.first { $0.id == "tt2" }?.metaItem)
        #expect(show.type == .series && show.posterShape == .landscape && show.name == "Alpha Show")

        model.order = .name
        model.typeFilter = .movie
        await model.reload()
        #expect(model.items.map(\.name) == ["Beta Film"])

        await model.remove(model.items[0])
        await model.reload()
        // The filter falls back to "all" when its type has nothing left.
        #expect(model.typeFilter == nil && model.items.map(\.name) == ["Alpha Show"])

        await model.clearHistory()
        await model.reload()
        #expect(model.history.isEmpty)
    }

    @Test("Continue Watching offers to resume what is unfinished and the next episode after a finished one")
    func continueWatching() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        fixture.harness.server.respond(to: "/meta/series/tt0000042.json", with: .json(AddonFixtures.seriesMetaJSON()))
        let center = fixture.center
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let pilot = WatchVideo(type: .series, videoID: "tt0000042:1:1", titleID: "tt0000042", titleName: "Example Show", season: 1, episode: 1)
        let film = WatchVideo(type: .movie, videoID: "tt0000001", titleID: "tt0000001", titleName: "Example Movie")
        try await fixture.history.begin(pilot, now: start)
        try await fixture.history.record(.finished, duration: 1200, type: .series, videoID: pilot.videoID, now: start + 10)
        try await fixture.history.begin(film, now: start + 20)
        try await fixture.history.record(.at(1500), duration: 6000, type: .movie, videoID: film.videoID, now: start + 30)

        let model = ContinueWatchingModel(library: center, client: fixture.harness.client)
        try await model.update(addons: [fixture.harness.installedAddon()])
        await model.reload()
        #expect(model.items.map(\.video.videoID) == ["tt0000001", "tt0000042:1:2"])
        #expect(model.items[0].kind == .resume && model.items[0].progress == 0.25)
        #expect(model.items[1].kind == .nextEpisode && model.items[1].video.videoTitle == "Second")

        // The episode list is fetched once, however often the row reloads.
        await model.reload()
        #expect(fixture.harness.server.requestCount(for: "/meta/series/tt0000042.json") == 1)

        await model.dismiss(model.items[1])
        #expect(model.items.map(\.video.videoID) == ["tt0000001"])
        await model.reload()
        #expect(model.items.map(\.video.videoID) == ["tt0000001"])
    }

    @Test("The detail page saves the title, marks films, episodes and seasons, and opens on a given episode")
    func detailPage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        fixture.harness.server.respond(to: "/meta/series/tt0000042.json", with: .json(AddonFixtures.seriesMetaJSON()))
        fixture.harness.server.respond(to: "/meta/movie/tt0000001.json", with: .json(AddonFixtures.movieMetaJSON()))
        let addons = try await [fixture.harness.installedAddon()]

        let series = DetailModel(route: MediaRoute(type: .series, id: "tt0000042"), client: fixture.harness.client, library: fixture.center)
        series.initialVideoID = "tt0000042:2:1"
        await series.load(addons: addons)
        // Opened for an episode of the second season: that season, that episode.
        #expect(series.selectedSeason == 2 && series.selectedVideoID == "tt0000042:2:1")
        #expect(!series.isInLibrary && series.watchEntries.isEmpty)

        await series.toggleLibrary()
        #expect(series.isInLibrary)
        #expect(await fixture.center.items().map(\.name) == ["Example Show"])
        await series.toggleLibrary()
        #expect(!series.isInLibrary)

        series.selectedSeason = 1
        let episodes = series.episodes
        #expect(!series.isSeasonWatched)
        await series.setWatched(true, video: episodes[0])
        #expect(series.isWatched(episodes[0]) && !series.isWatched(episodes[1]) && !series.isSeasonWatched)
        await series.setSeasonWatched(true)
        #expect(series.isSeasonWatched && series.watchEntries.count == 2)
        #expect(series.watchEntries["tt0000042:1:2"]?.video.videoTitle == "Second")
        await series.setSeasonWatched(false)
        #expect(!series.isSeasonWatched && !series.isWatched(episodes[0]))

        // An episode that was left half way shows how far it got.
        try await fixture.center.begin(#require(series.watchVideo(for: episodes[1])))
        try await fixture.history.record(.at(300), duration: 1200, type: .series, videoID: episodes[1].id)
        await series.refreshLibraryState()
        #expect(series.progress(of: episodes[1]) == 0.25 && series.progress(of: episodes[0]) == nil)

        let film = DetailModel(route: MediaRoute(type: .movie, id: "tt0000001"), client: fixture.harness.client, library: fixture.center)
        await film.load(addons: addons)
        #expect(!film.isTitleWatched)
        await film.setWatched(true)
        #expect(film.isTitleWatched)
        #expect(film.streamVideo?.watchVideo == WatchVideo(
            type: .movie, videoID: "tt0000001", titleID: "tt0000001", titleName: "Example Movie",
            poster: film.meta?.poster
        ))
    }

    @Test("The player's memory keeps catalog videos in the watch history and everything else apart")
    func playerMemory() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        let changes = Counter()
        let memory = LibraryPlayerMemory(
            store: PlaybackMemoryStore(database: fixture.harness.database),
            settings: SettingsStore(database: fixture.harness.database),
            history: fixture.history,
            historyChanged: { await changes.increment() }
        )
        let key = WatchKey.make(type: .series, videoID: "tt42:1:1")

        // Not begun through the app: nothing to resume, and nothing is created.
        await memory.remember(.at(100), duration: 1000, for: key)
        #expect(await memory.rememberedPosition(for: key) == nil)

        try await fixture.history.begin(watched(1, 1))
        await memory.remember(.at(100), duration: 1000, for: key)
        #expect(await memory.rememberedPosition(for: key) == 100)
        #expect(try await fixture.history.entry(type: .series, videoID: "tt42:1:1")?.progress == 0.1)
        await memory.remember(.finished, duration: 1000, for: key)
        // Watched to the end: next time it starts from the beginning.
        #expect(await memory.rememberedPosition(for: key) == nil)
        #expect(try await fixture.history.entry(type: .series, videoID: "tt42:1:1")?.isWatched == true)
        #expect(await changes.value == 3)

        // A local file: remembered, but not part of the history.
        await memory.remember(.at(55), duration: 500, for: "file:/films/a.mkv")
        #expect(await memory.rememberedPosition(for: "file:/films/a.mkv") == 55)
        await memory.remember(.notStarted, duration: 500, for: "file:/films/a.mkv")
        #expect(await memory.rememberedPosition(for: "file:/films/a.mkv") == nil)
        #expect(try await fixture.history.history().count == 1)
        #expect(await changes.value == 3)
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// A sample written by `Scripts/make-test-media.sh`: long enough to have a middle.
private let longSample = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "TestMedia/long-low-res.mp4")

@MainActor
@Suite("Watching through the app", .serialized)
struct WatchingTests {
    private func eventually(within timeout: Duration = .seconds(20), _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await condition()
    }

    @Test(
        "A stream that is watched part of the way lands in the history, on Continue Watching, and resumes there next time",
        .enabled(if: FileManager.default.fileExists(atPath: longSample.path), "run Scripts/make-test-media.sh first")
    )
    func watchAndResume() async throws {
        // The film is a generated sample, served over HTTP on this machine as an add-on's web stream would be.
        let server = StreamServer()
        try await server.start()
        let address = try await server.publish(#require(FileByteSource(url: longSample)), named: "film.mp4")
        let database = try LibraryDatabase.inMemory()
        let history = WatchHistoryStore(database: database)
        let center = LibraryCenter(library: LibraryStore(database: database), history: history)
        let coordinator = PlayerCoordinator(
            configuration: PlayerConfiguration(userAgent: "AppUITests/1.0", logSubsystem: "test.appui", videoOutput: .none, playsAudio: false),
            memory: LibraryPlayerMemory(
                store: PlaybackMemoryStore(database: database),
                settings: SettingsStore(database: database),
                history: history,
                historyChanged: { await center.noteChange() }
            ),
            presentsWindow: false
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)")
        let manager = StreamManager(settings: .loopback(), cache: StreamCache(directory: root))
        let player = StreamPlayer(coordinator: coordinator, manager: manager, library: center)
        defer {
            Task {
                await server.stop()
                await manager.shutdown()
            }
        }
        let stream = try JSONDecoder().decode(StreamItem.self, from: Data(#"{"url": "\#(address.absoluteString)", "name": "1080p"}"#.utf8))
        let choice = StreamChoice(stream: stream, addonID: "a", addonName: "Add-on", position: 0)
        let video = StreamVideo(
            type: .movie, videoID: "tt0000001", titleID: "tt0000001", title: "Example Movie",
            poster: URL(string: "https://images.example.com/poster/1.jpg")
        )

        player.play(choice, for: video)
        #expect(player.nowPlaying == video)
        let model = try #require(coordinator.player)
        #expect(await eventually { model.state.phase == .playing && model.state.hasShownFirstFrame })
        await model.waitForTrackSelection()
        #expect(model.state.position < 5)
        model.seek(to: 40)
        #expect(await eventually { abs(model.state.position - 40) < 1.5 })
        model.setPaused(true)

        // Paused: where it was left is in the history, with the film's name and poster.
        #expect(await eventually { await center.latestPerTitle().first?.isInProgress == true })
        let entry = try #require(await center.latestPerTitle().first)
        #expect(abs(entry.position - 40) < 2 && abs((entry.duration ?? 0) - 90) < 1)
        #expect(entry.video == video.watchVideo)
        #expect(center.revision > 0)
        let item = try #require(ContinueWatching.item(for: entry, videos: nil))
        // Fifty of its ninety seconds are left.
        #expect(item.kind == .resume && item.statusLine == "Less than a minute left")

        coordinator.closePlayer()
        #expect(await eventually { player.nowPlaying == nil })

        // Chosen again later: it carries on from there, and says so.
        player.play(choice, for: video)
        let again = try #require(coordinator.player)
        #expect(await eventually { again.state.phase == .playing && abs(again.state.position - 40) < 3 })
        #expect(again.notice?.text.hasPrefix("Resumed at 0:") == true)

        // Watched into the last seconds: it is finished, and no longer something to continue.
        again.seek(to: 86)
        #expect(await eventually { again.state.position > 85 })
        again.setPaused(true)
        #expect(await eventually { await center.entries(type: .movie, titleID: "tt0000001")["tt0000001"]?.isWatched == true })
        #expect(await center.latestPerTitle().compactMap { ContinueWatching.item(for: $0, videos: nil) }.isEmpty)
        coordinator.closePlayer()
    }
}
