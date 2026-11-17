import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary
import PlayerKit
import StreamEngine
import Testing

private func decodeStream(_ json: String) throws -> StreamItem {
    try JSONDecoder().decode(StreamItem.self, from: Data(json.utf8))
}

private func choice(_ json: String, addon: String = "a", position: Int = 0) throws -> StreamChoice {
    try StreamChoice(stream: decodeStream(json), addonID: addon, addonName: "Add-on \(addon.uppercased())", position: position)
}

@Suite("Reading and arranging streams (pure)")
struct StreamChoiceTests {
    @Test("Quality is read from the words add-ons use", arguments: [
        ("Example 2160p HDR", StreamQuality.uhd4K), ("4K\nDV", .uhd4K), ("Film.1080p.WEB", .hd1080), ("[720p] x264", .hd720),
        ("DVDRip", .sd), ("480p", .sd), ("1440p", .qhd1440),
    ])
    func quality(text: String, expected: StreamQuality) {
        #expect(StreamTextParser.quality(in: text) == expected)
    }

    @Test("Words that only look like a quality are not one")
    func noQuality() {
        #expect(StreamTextParser.quality(in: "Good release, 24k gold") == nil)
        #expect(StreamTextParser.quality(in: "") == nil)
    }

    @Test("Size is the largest one mentioned", arguments: [
        ("💾 1.4 GB", 1_503_238_553), ("700MB x264", 734_003_200), ("Pack 40 GB, this file 2,5 GB", 42_949_672_960),
        ("1 TB", 1_099_511_627_776),
    ] as [(String, Int64)])
    func size(text: String, expected: Int64) {
        #expect(StreamTextParser.size(in: text) == expected)
    }

    @Test("A stream's kind, title, size and quality come from what the add-on sent")
    func choices() throws {
        let torrent = try choice(#"""
        {"infoHash": "ABCDEF0123456789ABCDEF0123456789ABCDEF01", "fileIdx": 2, "name": "Add-on\n1080p", "title": "Film.2020.1080p.WEB\n👤 12 💾 2.1 GB",
         "behaviorHints": {"bingeGroup": "x|1080p", "filename": "Film.2020.1080p.WEB.mkv"}}
        """#)
        #expect(torrent.kind == .torrent && torrent.kindLabel == "Torrent")
        #expect(torrent.title == "Add-on 1080p")
        #expect(torrent.quality == .hd1080)
        #expect(torrent.sizeBytes == Int64(2.1 * 1_073_741_824))
        #expect(torrent.id == "a#0")

        // A size the add-on states outright wins over one found in the text.
        let direct = try choice(#"{"url": "https://cdn.example.com/a.mp4", "description": "720p 900 MB", "behaviorHints": {"videoSize": 1000}}"#)
        #expect(direct.kind == .direct && direct.sizeBytes == 1000 && direct.quality == .hd720)
        #expect(direct.title == "Add-on A")
        #expect(try choice(#"{"ytId": "abcdefghijk"}"#).kind == .youTube)
        #expect(try choice(#"{"externalUrl": "https://example.com/watch"}"#).kind == .external)
    }

    @Test("Streams are grouped by quality (best first, larger first), by size, or by add-on")
    func grouping() throws {
        let choices = try [
            choice(#"{"url": "https://e.com/1", "name": "720p", "description": "1 GB"}"#, addon: "a", position: 0),
            choice(#"{"url": "https://e.com/2", "name": "4K", "description": "20 GB"}"#, addon: "a", position: 1),
            choice(#"{"url": "https://e.com/3", "name": "unknown"}"#, addon: "b", position: 0),
            choice(#"{"url": "https://e.com/4", "name": "2160p", "description": "45 GB"}"#, addon: "b", position: 1),
            choice(#"{"url": "https://e.com/5", "name": "720p"}"#, addon: "b", position: 2),
        ]
        let byQuality = StreamGroup.groups(of: choices, by: .quality)
        #expect(byQuality.map(\.title) == ["4K", "720p", "Other"])
        #expect(byQuality[0].choices.map(\.id) == ["b#1", "a#1"])
        // Unknown sizes come after known ones, in the order they arrived.
        #expect(byQuality[1].choices.map(\.id) == ["a#0", "b#2"])

        let bySize = StreamGroup.groups(of: choices, by: .size)
        #expect(bySize.count == 1)
        #expect(bySize[0].choices.map(\.id) == ["b#1", "a#1", "a#0", "b#0", "b#2"])

        let bySource = StreamGroup.groups(of: choices, by: .source)
        #expect(bySource.map(\.title) == ["Add-on A", "Add-on B"])
        #expect(bySource[1].choices.map(\.id) == ["b#0", "b#1", "b#2"])
        #expect(StreamGroup.groups(of: [], by: .quality).isEmpty)
        // With no quality known at all, the one group is not called "Other".
        #expect(StreamGroup.groups(of: [choices[2]], by: .quality).map(\.title) == ["Streams"])
    }

    @Test("The stream most like last time's: same add-on and release group, else same add-on and quality")
    func lastChoice() throws {
        let played = try choice(#"{"infoHash": "abcdef0123456789abcdef0123456789abcdef01", "name": "1080p", "behaviorHints": {"bingeGroup": "grp-1080"}}"#)
        let last = LastStreamChoice(played)
        let nextEpisode = try [
            choice(#"{"infoHash": "1111111111111111111111111111111111111111", "name": "1080p", "behaviorHints": {"bingeGroup": "other"}}"#, position: 0),
            choice(#"{"infoHash": "2222222222222222222222222222222222222222", "name": "720p", "behaviorHints": {"bingeGroup": "grp-1080"}}"#, position: 1),
            choice(
                #"{"infoHash": "3333333333333333333333333333333333333333", "name": "1080p", "behaviorHints": {"bingeGroup": "grp-1080"}}"#,
                addon: "b",
                position: 0
            ),
        ]
        // The group wins over the quality label; another add-on's identical group does not count.
        #expect(last.bestMatch(in: nextEpisode)?.id == "a#1")
        // No such group this time: same add-on, same quality, same kind.
        #expect(last.bestMatch(in: [nextEpisode[0], nextEpisode[2]])?.id == "a#0")
        #expect(last.bestMatch(in: [nextEpisode[2]]) == nil)
        let direct = try choice(#"{"url": "https://e.com/x", "name": "1080p"}"#)
        #expect(last.bestMatch(in: [direct]) == nil)
        // Survives being stored.
        #expect(try JSONDecoder().decode(LastStreamChoice.self, from: JSONEncoder().encode(last)) == last)
    }
}

@MainActor
@Suite("Stream list from installed add-ons")
struct StreamListModelTests {
    private static func streamManifest(id: String, name: String) -> String {
        """
        {"id": "\(id)", "version": "1.0.0", "name": "\(name)", "resources": ["stream"], "types": ["movie", "series"],
         "idPrefixes": ["tt"], "catalogs": []}
        """
    }

    private struct Fixture {
        let harness: AddonHarness
        let addons: [InstalledAddon]
    }

    /// Two stream add-ons under `/one/` and `/two/`, plus the catalog add-on at the root (which offers no streams).
    private func makeFixture() async throws -> Fixture {
        let harness = try await AddonHarness.make()
        var addons = try await [harness.installedAddon()]
        for (prefix, name) in [("one", "First Streams"), ("two", "Second Streams")] {
            harness.server.respond(to: "/\(prefix)/manifest.json", with: .json(Self.streamManifest(id: "test.\(prefix)", name: name)))
            let address = try harness.address(prefix)
            try await addons.append(InstalledAddon(address: address, manifest: harness.client.manifest(at: address)))
        }
        return Fixture(harness: harness, addons: addons)
    }

    @Test("Every add-on that offers streams is asked, and the answers are merged in install order")
    func merges() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        fixture.harness.server.respond(to: "/one/stream/series/tt0000042%3A1%3A2.json", with: .json(#"""
        {"streams": [{"url": "https://cdn.example.com/a.mp4", "name": "720p"}, {"nothing": "usable"},
                     {"infoHash": "abcdef0123456789abcdef0123456789abcdef01", "name": "1080p", "description": "3 GB"}]}
        """#))
        fixture.harness.server.respond(to: "/two/stream/series/tt0000042%3A1%3A2.json", with: .json(#"""
        {"streams": [{"url": "https://cdn.example.com/b.mkv", "name": "4K"}]}
        """#, delay: .milliseconds(80)))

        let model = StreamListModel(client: fixture.harness.client)
        model.load(type: .series, videoID: "tt0000042:1:2", titleID: "tt0000042", addons: fixture.addons)
        #expect(model.phase == .loading && model.hasProviders)
        await model.waitForLoad()
        #expect(model.phase == .finished)
        #expect(model.choices.map(\.addonName) == ["First Streams", "First Streams", "Second Streams"])
        #expect(model.groups.map(\.title) == ["4K", "1080p", "720p"])
        #expect(model.failedAddonNames.isEmpty && model.suggested == nil)
        // The catalog add-on has no stream resource and was not asked.
        #expect(fixture.harness.server.requestCount(for: "/stream/series/tt0000042%3A1%3A2.json") == 0)

        model.sort = .source
        #expect(model.groups.map(\.title) == ["First Streams", "Second Streams"])
        model.clear()
        #expect(model.phase == .idle && model.groups.isEmpty && model.videoID == nil)
    }

    @Test("An add-on that fails is named, and the others' streams are still shown")
    func partialFailure() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        fixture.harness.server.respond(to: "/one/stream/movie/tt0000001.json", with: .status(500))
        fixture.harness.server.respond(to: "/two/stream/movie/tt0000001.json", with: .json(#"{"streams": [{"url": "https://cdn.example.com/b.mkv"}]}"#))
        let model = StreamListModel(client: fixture.harness.client)
        model.load(type: .movie, videoID: "tt0000001", titleID: "tt0000001", addons: fixture.addons)
        await model.waitForLoad()
        #expect(model.failedAddonNames == ["First Streams"])
        #expect(model.choices.count == 1)
    }

    @Test("With no add-on offering streams, nothing is asked and the list says so")
    func noProviders() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        let model = StreamListModel(client: fixture.harness.client)
        model.load(type: .movie, videoID: "tt0000001", titleID: "tt0000001", addons: [fixture.addons[0]])
        #expect(model.phase == .finished && !model.hasProviders && model.choices.isEmpty)
        // An id the stream add-ons do not handle.
        model.load(type: .movie, videoID: "kitsu:1", titleID: "kitsu:1", addons: fixture.addons)
        #expect(!model.hasProviders)
    }

    @Test("The source played last time for a title is remembered and offered first next time")
    func remembersSource() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        let memory = LibraryStreamChoiceMemory(store: PlaybackMemoryStore(database: fixture.harness.database))
        for episode in ["1", "2"] {
            fixture.harness.server.respond(to: "/one/stream/series/tt0000042%3A1%3A\(episode).json", with: .json(#"""
            {"streams": [{"url": "https://cdn.example.com/e\#(episode)-720.mp4", "name": "720p", "behaviorHints": {"bingeGroup": "one|720"}},
                         {"url": "https://cdn.example.com/e\#(episode)-1080.mp4", "name": "1080p", "behaviorHints": {"bingeGroup": "one|1080"}}]}
            """#))
            fixture.harness.server.respond(to: "/two/stream/series/tt0000042%3A1%3A\(episode).json", with: .json(#"{"streams": []}"#))
        }
        let first = StreamListModel(client: fixture.harness.client, memory: memory)
        first.load(type: .series, videoID: "tt0000042:1:1", titleID: "tt0000042", addons: fixture.addons)
        await first.waitForLoad()
        #expect(first.suggested == nil)
        let played = try #require(first.choices.first { $0.quality == .hd1080 })
        first.didChoose(played)
        #expect(first.suggested == played)

        // The next episode, on a fresh page.
        for _ in 0 ..< 100 where await memory.lastChoice(for: "tt0000042") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let next = StreamListModel(client: fixture.harness.client, memory: memory)
        next.load(type: .series, videoID: "tt0000042:1:2", titleID: "tt0000042", addons: fixture.addons)
        await next.waitForLoad()
        #expect(try next.suggested?.stream.source == .url(#require(URL(string: "https://cdn.example.com/e2-1080.mp4"))))
    }
}

/// A sample written by `Scripts/make-test-media.sh`.
private let streamSample = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "TestMedia/sdr-h264-1080p.mp4")

@MainActor
@Suite("Playing a chosen stream", .serialized)
struct StreamPlayerTests {
    private let video = StreamVideo(type: .series, videoID: "tt0000042:1:2", titleID: "tt0000042", title: "Example Show — 2. Two")

    private func makeCoordinator() -> PlayerCoordinator {
        PlayerCoordinator(
            configuration: PlayerConfiguration(userAgent: "AppUITests/1.0", logSubsystem: "test.appui", playsAudio: false),
            presentsWindow: false
        )
    }

    private func makeManager(root: URL) -> StreamManager {
        StreamManager(settings: .loopback(), cache: StreamCache(directory: root.appendingPathComponent("cache")))
    }

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

    @Test("A video is remembered under its own identity, not under an address that changes every time")
    func memoryKeys() {
        #expect(video.memoryKeys == ["video:series:tt0000042:1:2", "title:series:tt0000042"])
    }

    @Test("YouTube streams go to the embedded player, web pages to the browser, and nothing else leaves the app")
    func otherKinds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)")
        var opened: [URL] = []
        let player = StreamPlayer(coordinator: makeCoordinator(), manager: makeManager(root: root)) { opened.append($0) }

        try player.play(choice(#"{"ytId": "abcdefghijk"}"#), for: video)
        #expect(player.youTubeVideo?.rawValue == "abcdefghijk" && player.phase == .idle)
        try player.play(choice(#"{"ytId": "<script>"}"#), for: video)
        #expect(player.phase == .failed(title: video.title, message: "This stream points to a YouTube video that cannot be shown."))

        try player.play(choice(#"{"externalUrl": "https://example.com/watch"}"#), for: video)
        #expect(opened.map(\.absoluteString) == ["https://example.com/watch"] && player.phase == .idle)
        // An add-on must not be able to open files or other apps.
        try player.play(choice(#"{"externalUrl": "file:///Applications/Calculator.app"}"#), for: video)
        try player.play(choice(#"{"externalUrl": "ssh://example.com"}"#), for: video)
        #expect(opened.count == 1)
        #expect(player.phase == .failed(title: video.title, message: "This stream points to something that is not a web page."))
        player.cancel()
        #expect(player.phase == .idle)

        // A torrent "stream" whose hash is not one never reaches the engine.
        #expect(throws: (any Error).self) { try decodeStream(#"{"infoHash": "nothex"}"#) }
    }

    @Test("Progress while a torrent is being found is said in words")
    func progressText() {
        var status = TorrentStatus(
            hasMetadata: false, downloadRate: 0, uploadRate: 0, peers: 0, seeds: 0,
            wantedBytes: 0, wantedBytesDone: 0, isFinished: false, errorMessage: nil
        )
        #expect(StreamPlayer.progressText(for: status) == "Looking for people sharing this…")
        status.peers = 1
        #expect(StreamPlayer.progressText(for: status) == "Connected to 1 person sharing this…")
        status.peers = 4
        #expect(StreamPlayer.progressText(for: status) == "Connected to 4 people sharing this…")
        status.hasMetadata = true
        status.downloadRate = 2_500_000
        // The speed is formatted by the system in the user's own number format.
        let starting = StreamPlayer.progressText(for: status)
        #expect(starting.hasPrefix("Starting: 4 connections, ") && starting.hasSuffix("/s") && starting.contains("MB"))
    }

    @Test("A torrent nobody is sharing fails with an explanation, and can be cancelled while it is being looked for")
    func torrentFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        let coordinator = makeCoordinator()
        let player = StreamPlayer(coordinator: coordinator, manager: manager)
        let lonely = try choice(#"{"infoHash": "abababababababababababababababababababab", "name": "1080p"}"#)

        player.play(lonely, for: video)
        #expect(player.phase == .preparing(title: video.title, detail: "Looking for people sharing this…"))
        #expect(await eventually { await manager.isFetching("abababababababababababababababababababab") })
        player.cancel()
        #expect(player.phase == .idle)
        #expect(await eventually { await !manager.isFetching("abababababababababababababababababababab") })
        #expect(!coordinator.isPlayerOpen)
        await manager.shutdown()
    }

    @Test(
        "A torrent stream plays: found on a peer, served on the loopback interface, shown by the player, stopped when the player closes",
        .enabled(if: FileManager.default.fileExists(atPath: streamSample.path), "run Scripts/make-test-media.sh first")
    )
    func playsTorrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)")
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Someone on this machine shares the generated sample.
        let file = shared.appendingPathComponent("Example.Show.S01E02.1080p.mp4")
        try FileManager.default.copyItem(at: streamSample, to: file)
        let torrentFile = root.appendingPathComponent("sample.torrent")
        let infoHash = try TorrentCreator.makeTorrent(forFile: file, output: torrentFile)
        let seeder = TorrentEngine(settings: .loopback(), directory: root.appendingPathComponent("seeder"))
        #expect(try await seeder.seed(torrentFile: torrentFile, dataDirectory: shared) == infoHash)

        let manager = makeManager(root: root)
        let coordinator = makeCoordinator()
        let player = StreamPlayer(coordinator: coordinator, manager: manager)
        let torrent = try choice(
            #"{"infoHash": "\#(infoHash)", "name": "1080p", "sources": ["tracker:udp://tracker.invalid:1337/announce", "dht:\#(infoHash)"]}"#
        )

        let started = ContinuousClock.now
        player.play(torrent, for: video)
        guard case .preparing = player.phase else {
            Issue.record("expected the stream to be preparing, got \(player.phase)")
            return
        }
        // Introduce the two engines, as a tracker would.
        #expect(await eventually { await manager.isFetching(infoHash) })
        #expect(await eventually { await seeder.listenPort != 0 })
        await manager.connect(infoHash, toPeerAt: "127.0.0.1", port: seeder.listenPort)

        #expect(await eventually { coordinator.isPlayerOpen })
        #expect(player.phase == .idle && player.activeTorrent == infoHash)
        let model = try #require(coordinator.player)
        #expect(model.source?.url.host == "127.0.0.1")
        #expect(model.source?.url.lastPathComponent == "Example.Show.S01E02.1080p.mp4")
        #expect(await eventually { model.state.phase == .playing && model.state.hasShownFirstFrame })
        // From choosing the stream to its first frame, with the peer on this machine.
        let toFirstFrame = ContinuousClock.now - started
        print("torrent-stream-first-frame-ms=\(Int(toFirstFrame / .milliseconds(1)))")
        #expect(toFirstFrame < .seconds(5))
        #expect(model.title == video.title)
        #expect(await eventually { model.state.position > 1 })
        #expect(abs((model.state.duration ?? 0) - 10) < 0.5)
        // Remembered as the episode it is, and no second reader for seek-bar stills.
        #expect(model.currentMemoryKeys == video.memoryKeys)
        #expect(!model.canPreviewFrames)

        // Seeking far ahead works while the file is still arriving.
        model.seek(to: 8)
        #expect(await eventually { abs(model.state.position - 8) < 1 })

        coordinator.closePlayer()
        #expect(await eventually { await manager.openStreams.isEmpty })
        #expect(player.activeTorrent == nil)
        // What was fetched stays in the cache for next time.
        #expect(await manager.cacheSize() > 1_000_000)
        await manager.shutdown()
        await seeder.shutdown()
    }
}

@MainActor
@Suite("Streams on the detail page")
struct DetailStreamTests {
    private static let streamManifest = """
    {"id": "test.streams", "version": "1.0.0", "name": "Test Streams", "resources": ["stream"], "types": ["movie", "series"],
     "idPrefixes": ["tt"], "catalogs": []}
    """

    /// The catalog add-on at the root (details) and a stream add-on under `/streams/`.
    private func makeAddons(_ harness: AddonHarness) async throws -> [InstalledAddon] {
        harness.server.respond(to: "/streams/manifest.json", with: .json(Self.streamManifest))
        let address = try harness.address("streams")
        return try await [harness.installedAddon(), InstalledAddon(address: address, manifest: harness.client.manifest(at: address))]
    }

    @Test("A film's streams load with the page")
    func film() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        harness.server.respond(to: "/meta/movie/tt0000001.json", with: .json(AddonFixtures.movieMetaJSON()))
        harness.server.respond(
            to: "/streams/stream/movie/tt0000001.json",
            with: .json(#"{"streams": [{"url": "https://cdn.example.com/film.mp4", "name": "1080p"}]}"#)
        )
        let model = DetailModel(route: MediaRoute(type: .movie, id: "tt0000001"), client: harness.client)
        #expect(!model.isSingleVideo && model.streamVideo == nil)

        try await model.load(addons: makeAddons(harness))
        await model.streams.waitForLoad()
        #expect(model.isSingleVideo)
        #expect(model.streams.choices.map(\.title) == ["1080p"])
        let video = try #require(model.streamVideo)
        #expect(video.videoID == "tt0000001" && video.titleID == "tt0000001" && video.title == "Example Movie" && video.type == .movie)
        // The film's poster goes along, for the watch history.
        #expect(video.poster == model.meta?.poster)
    }

    @Test("An episode's streams show when it is chosen and go when it is chosen again; only one episode at a time")
    func episodes() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        harness.server.respond(to: "/meta/series/tt0000042.json", with: .json(AddonFixtures.seriesMetaJSON()))
        harness.server.respond(
            to: "/streams/stream/series/tt0000042%3A1%3A1.json",
            with: .json(#"{"streams": [{"url": "https://cdn.example.com/e1.mp4", "name": "E1"}]}"#)
        )
        harness.server.respond(
            to: "/streams/stream/series/tt0000042%3A1%3A2.json",
            with: .json(#"{"streams": [{"url": "https://cdn.example.com/e2.mp4", "name": "E2"}]}"#)
        )
        let model = DetailModel(route: MediaRoute(type: .series, id: "tt0000042"), client: harness.client)
        try await model.load(addons: makeAddons(harness))
        // A series has no streams of its own.
        #expect(!model.isSingleVideo && model.streams.phase == .idle && model.selectedVideoID == nil)

        let episodes = model.episodes
        model.toggleStreams(for: episodes[0])
        await model.streams.waitForLoad()
        #expect(model.selectedVideoID == "tt0000042:1:1")
        #expect(model.streams.choices.map(\.title) == ["E1"])
        #expect(model.streamVideo?.title == "Example Show — 1. Pilot")
        #expect(model.streamVideo?.memoryKeys == ["video:series:tt0000042:1:1", "title:series:tt0000042"])

        model.toggleStreams(for: episodes[1])
        await model.streams.waitForLoad()
        #expect(model.selectedVideoID == "tt0000042:1:2" && model.streams.choices.map(\.title) == ["E2"])

        model.toggleStreams(for: episodes[1])
        #expect(model.selectedVideoID == nil && model.streams.choices.isEmpty && model.streamVideo == nil)
    }
}
