import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary
import PlayerKit
import StreamEngine
import Testing

private func choice(_ json: String, position: Int = 0) throws -> StreamChoice {
    let stream = try JSONDecoder().decode(StreamItem.self, from: Data(json.utf8))
    return StreamChoice(stream: stream, addonID: "a", addonName: "Add-on A", position: position)
}

private let film = StreamVideo(type: .movie, videoID: "tt0000007", titleID: "tt0000007", title: "Example Film")
private let episode = StreamVideo(
    type: .series, videoID: "tt0000042:2:5", titleID: "tt0000042", title: "Example Show — 5. Five",
    titleName: "Example Show", season: 2, episode: 5, episodeTitle: "Five"
)

@Suite("What the busy indicator says while the player waits for a torrent")
struct ArrivalMeterTests {
    @Test("The fraction shown never goes backward while the player waits, and starts afresh for the next wait")
    func neverGoesBackward() {
        var meter = ArrivalMeter()
        #expect(meter.read(nil) == nil)
        #expect(meter.read(ArrivalProgress(bytesDone: 2, bytesWanted: 8)) == 0.25)
        #expect(meter.read(ArrivalProgress(bytesDone: 6, bytesWanted: 8)) == 0.75)
        // The player asks for another piece: more is wanted, so the true share drops. Not shown.
        #expect(meter.read(ArrivalProgress(bytesDone: 8, bytesWanted: 16)) == 0.75)
        // Nothing is waited for at this instant: what was there stays.
        #expect(meter.read(nil) == 0.75)
        #expect(meter.read(ArrivalProgress(bytesDone: 16, bytesWanted: 16)) == 1)

        meter.reset()
        #expect(meter.read(nil) == nil)
        #expect(meter.read(ArrivalProgress(bytesDone: 1, bytesWanted: 10)) == 0.1)
    }

    @Test("How long is left is said roughly, and not at all when it cannot be known", arguments: [
        (Int64(0), 1000, String?.none),
        (Int64(5_000_000), 0, nil),
        // Under three seconds a figure would be out of date before it is read.
        (Int64(2000), 1000, nil),
        (Int64(7000), 1000, "a few seconds left"),
        (Int64(23000), 1000, "about 25 s left"),
        (Int64(88000), 1000, "about 90 s left"),
        (Int64(600_000), 1000, "about 10 min left"),
        (Int64(9_000_000), 1000, "over an hour left"),
    ])
    func timeLeft(bytes: Int64, rate: Int, expected: String?) {
        #expect(ArrivalMeter.timeLeft(bytes: bytes, rate: rate) == expected)
    }

    @Test("The note under the percentage adds how long is left to the connections and the speed")
    func waitingNote() {
        var status = TorrentStatus(
            hasMetadata: true, downloadRate: 700_000, uploadRate: 0, peers: 7, seeds: 3,
            wantedBytes: 100, wantedBytesDone: 0, isFinished: false, errorMessage: nil
        )
        let note = StreamPlayer.waitingNote(for: status, bytesLeft: 16 << 20)
        #expect(note.hasPrefix("7 connections · ") && note.hasSuffix("/s · about 25 s left"))
        // Nothing known of what is left, or nothing arriving: no figure.
        #expect(StreamPlayer.waitingNote(for: status, bytesLeft: nil).hasSuffix("/s"))
        status.downloadRate = 0
        #expect(StreamPlayer.waitingNote(for: status, bytesLeft: 16 << 20).hasSuffix("/s"))
        status.peers = 0
        #expect(StreamPlayer.waitingNote(for: status, bytesLeft: 16 << 20) == "Looking for people sharing this…")
    }
}

@Suite("A download, as the list shows it")
struct DownloadItemTests {
    @Test("A torrent or one file on a web server can be downloaded; a playlist, a YouTube video or a web page cannot")
    func sources() throws {
        let torrent = try choice(#"""
        {"infoHash": "ABCDEF0123456789abcdef0123456789abcdef01", "fileIdx": 3,
         "sources": ["tracker:udp://tracker.example.org:1337/announce", "dht:abc"], "behaviorHints": {"filename": "Film.mkv"}}
        """#)
        #expect(DownloadItem.Source(torrent.stream) == .torrent(
            infoHash: "abcdef0123456789abcdef0123456789abcdef01", fileIndex: 3, fileName: "Film.mkv",
            trackers: ["udp://tracker.example.org:1337/announce"]
        ))
        let direct = try choice(#"""
        {"url": "https://cdn.example.com/film.mp4", "behaviorHints": {"proxyHeaders": {"request": {"Referer": "https://example.com"}}}}
        """#)
        let address = try #require(URL(string: "https://cdn.example.com/film.mp4"))
        #expect(DownloadItem.Source(direct.stream) == .direct(url: address, headers: ["Referer": "https://example.com"]))
        #expect(DownloadCenter.canDownload(torrent) && DownloadCenter.canDownload(direct))

        for json in [
            #"{"url": "https://cdn.example.com/live/master.m3u8"}"#,
            #"{"url": "https://cdn.example.com/manifest.MPD"}"#,
            #"{"ytId": "abcdefghijk"}"#,
            #"{"externalUrl": "https://example.com/watch"}"#,
        ] {
            #expect(try !DownloadCenter.canDownload(choice(json)), "\(json) should not be downloadable")
        }
    }

    @Test("Its line says where it stands, with speed and time left while it is arriving")
    func statusLine() {
        let source = DownloadItem.Source.direct(url: URL(filePath: "/x"), headers: [:])
        var item = DownloadItem(video: film, summary: "1080p · 2 GB · Add-on A", source: source, bytesTotal: 2_000_000_000)
        #expect(item.statusLine == "Waiting for its turn" && item.fraction == 0)
        item.activity = .waitingForPlayer
        #expect(item.statusLine == "Waiting until nothing is playing")
        item.activity = .findingPeers
        #expect(item.statusLine == "Looking for people sharing this…")

        item.bytesDone = 500_000_000
        item.activity = .downloading(rate: 5_000_000, peers: 12)
        #expect(item.fraction == 0.25)
        let parts = item.statusLine.components(separatedBy: " · ")
        #expect(parts.count == 4 && parts[0].contains(" of ") && parts[1].hasSuffix("/s"))
        #expect(parts[2] == "12 connections" && parts[3] == "about 5 min left")
        // A file from a web server comes from no "connections".
        item.activity = .downloading(rate: 5_000_000, peers: nil)
        #expect(item.statusLine.components(separatedBy: " · ").count == 3)

        item.stage = .paused
        #expect(item.statusLine.hasPrefix("Paused · "))
        item.stage = .failed
        item.failure = "The server would not send the file (it answered 404)."
        #expect(item.statusLine == "The server would not send the file (it answered 404).")
        item.stage = .finished
        #expect(item.statusLine.hasPrefix("Downloaded · ") && item.fraction == 1)

        // Until the size is known there is no share to show.
        let unknown = DownloadItem(video: film, summary: "", source: .direct(url: URL(filePath: "/x"), headers: [:]))
        #expect(unknown.fraction == nil)
    }

    @Test("It is remembered with everything but what it is doing this moment, and belongs to its video")
    func storage() throws {
        var item = DownloadItem(
            video: episode, summary: "4K · Add-on A",
            source: .torrent(infoHash: "abcdef0123456789abcdef0123456789abcdef01", fileIndex: nil, fileName: nil, trackers: [])
        )
        item.stage = .paused
        item.bytesDone = 42
        item.activity = .downloading(rate: 1, peers: 1)
        let restored = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        #expect(restored.activity == nil)
        var expected = item
        expected.activity = nil
        #expect(restored == expected)

        #expect(item.isFor(episode) && !item.isFor(film))
        #expect(item.episodeLine == "S2 · E5 · Five")
        #expect(DownloadItem(video: film, summary: "", source: item.source).episodeLine == nil)
    }

    @Test("The list is what is on its way, then what is here, newest first")
    func sections() {
        func item(_ id: String, _ stage: DownloadItem.Stage) -> DownloadItem {
            var item = DownloadItem(id: id, video: film, summary: "", source: .direct(url: URL(filePath: "/x"), headers: [:]))
            item.stage = stage
            return item
        }
        let items = [item("a", .finished), item("b", .queued), item("c", .finished), item("d", .failed), item("e", .paused)]
        let (pending, finished) = DownloadsView.sections(of: items)
        #expect(pending.map(\.id) == ["b", "d", "e"] && finished.map(\.id) == ["c", "a"])
        #expect(DownloadsView.summary(of: items) == "2 on this Mac · 3 on their way")
        #expect(DownloadsView.summary(of: [items[1]]) == "1 on its way")
        #expect(DownloadsView.summary(of: [items[0]]) == "1 on this Mac")
    }

    @Test("A finished file gets a name that is free, safe, and a video's")
    func names() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(DownloadCenter.freeLocation(for: "Film.mkv", in: folder).lastPathComponent == "Film.mkv")
        try Data().write(to: folder.appendingPathComponent("Film.mkv"))
        #expect(DownloadCenter.freeLocation(for: "Film.mkv", in: folder).lastPathComponent == "Film 2.mkv")
        try Data().write(to: folder.appendingPathComponent("Film 2.mkv"))
        #expect(DownloadCenter.freeLocation(for: "Film.mkv", in: folder).lastPathComponent == "Film 3.mkv")
        #expect(DownloadCenter.freeLocation(for: "No Extension", in: folder).lastPathComponent == "No Extension")

        // Never a path, never hidden, never nothing.
        #expect(DownloadCenter.safeFileName("../../etc/passwd") == "-..-etc-passwd")
        #expect(DownloadCenter.safeFileName("Show: The Film.mkv") == "Show- The Film.mkv")
        #expect(DownloadCenter.safeFileName(".hidden") == "hidden")
        #expect(DownloadCenter.safeFileName("  ") == "Download")

        let address = try #require(URL(string: "https://cdn.example.com/get/0f3a?token=1"))
        #expect(DownloadCenter.fileName(suggested: "Example.Film.1080p.mkv", url: address, title: "Example Film") == "Example.Film.1080p.mkv")
        // A server's "download" or "0f3a" says nothing: the title does.
        #expect(DownloadCenter.fileName(suggested: "0f3a", url: address, title: "Example Film") == "Example Film.mp4")
        let named = try #require(URL(string: "https://cdn.example.com/films/a.webm"))
        #expect(DownloadCenter.fileName(suggested: nil, url: named, title: nil) == "a.webm")
    }
}

@MainActor
@Suite("Downloads from start to finish", .serialized)
struct DownloadCenterTests {
    private struct Fixture {
        let root: URL
        let manager: StreamManager
        let store: DownloadStore
        let center: DownloadCenter

        var folder: URL {
            root.appendingPathComponent("Downloads")
        }

        func tearDown() async {
            await manager.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(database: LibraryDatabase? = nil, root existing: URL? = nil) throws -> Fixture {
        let root = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)")
        let manager = StreamManager(settings: .loopback(), cache: StreamCache(directory: root.appendingPathComponent("cache")))
        let store = try DownloadStore(database: database ?? .inMemory())
        let center = DownloadCenter(manager: manager, store: store, directory: root.appendingPathComponent("Downloads"), userAgent: "Tests/1.0")
        center.pollInterval = .milliseconds(40)
        center.retryPolicy = RetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(20), maxDelay: .milliseconds(40))
        center.discardFile = { try? FileManager.default.removeItem(at: $0) }
        return Fixture(root: root, manager: manager, store: store, center: center)
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

    @Test("A file on a web server is fetched, named, listed as finished and remembered; removing it takes the file away")
    func directDownload() async throws {
        let server = try MockAddonServer()
        let base = try await server.start()
        defer { server.stop() }
        let contents = Data((0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        server.respond(to: "/films/a.mp4", with: .init(body: contents, contentType: "video/mp4"))
        let database = try LibraryDatabase.inMemory()
        let fixture = try makeFixture(database: database)
        await fixture.center.load()

        let stream = try choice(#"{"url": "\#(base.absoluteString)films/a.mp4", "name": "1080p"}"#)
        let added = try #require(fixture.center.add(stream, for: film))
        #expect(added.stage == .queued && fixture.center.pendingCount == 1)
        // Asking again is the same download, not a second one.
        #expect(fixture.center.add(stream, for: film)?.id == added.id && fixture.center.items.count == 1)
        await fixture.center.waitUntilIdle()

        let item = try #require(fixture.center.item(for: film))
        #expect(item.stage == .finished && item.failure == nil && item.activity == nil)
        let file = try #require(fixture.center.finishedFile(for: film))
        #expect(file.deletingLastPathComponent().path == fixture.folder.path)
        // It keeps the name it has on the server, which is a video's.
        #expect(file.lastPathComponent == "a.mp4")
        #expect(try Data(contentsOf: file) == contents)
        #expect(item.bytesTotal == Int64(contents.count) && item.fraction == 1 && fixture.center.pendingCount == 0)
        #expect(item.summary == "1080p · Add-on A")

        // The next launch finds it, as long as the file is where it was.
        #expect(await eventually { await (try? fixture.store.all(as: DownloadItem.self))?.first?.stage == .finished })
        let relaunched = try makeFixture(database: database, root: fixture.root)
        await relaunched.center.load()
        #expect(relaunched.center.finishedFile(for: film) == file)

        relaunched.center.remove(item.id)
        #expect(relaunched.center.items.isEmpty && !FileManager.default.fileExists(atPath: file.path))
        #expect(await eventually { await (try? fixture.store.all(as: DownloadItem.self))?.isEmpty == true })
        await relaunched.manager.shutdown()
        await fixture.tearDown()
    }

    @Test("A file deleted in the Finder is no longer offered to play; a refusal is said in words and can be tried again")
    func missingAndRefused() async throws {
        let server = try MockAddonServer()
        let base = try await server.start()
        defer { server.stop() }
        server.respond(to: "/gone.mp4", with: .status(404))
        let database = try LibraryDatabase.inMemory()
        let fixture = try makeFixture(database: database)
        await fixture.center.load()

        let stream = try choice(#"{"url": "\#(base.absoluteString)gone.mp4"}"#)
        fixture.center.add(stream, for: film)
        await fixture.center.waitUntilIdle()
        var item = try #require(fixture.center.item(for: film))
        #expect(item.stage == .failed && item.failure == "The server would not send the file (it answered 404).")
        #expect(fixture.center.finishedFile(for: film) == nil)
        // A refusal is not asked for again and again.
        #expect(server.requestCount(for: "/gone.mp4") == 1)

        // The file turns up on the server; trying again fetches it.
        server.respond(to: "/gone.mp4", with: .init(body: Data(repeating: 7, count: 2000), contentType: "video/mp4"))
        fixture.center.resume(item.id)
        await fixture.center.waitUntilIdle()
        item = try #require(fixture.center.item(for: film))
        #expect(item.stage == .finished)
        let file = try #require(fixture.center.finishedFile(for: film))

        try FileManager.default.removeItem(at: file)
        #expect(fixture.center.finishedFile(for: film) == nil)
        #expect(await eventually { await (try? fixture.store.all(as: DownloadItem.self))?.first?.stage == .finished })
        let relaunched = try makeFixture(database: database, root: fixture.root)
        await relaunched.center.load()
        #expect(relaunched.center.item(for: film)?.stage == .failed)
        #expect(relaunched.center.item(for: film)?.failure == "The file is no longer where it was saved.")
        await relaunched.manager.shutdown()
        await fixture.tearDown()
    }

    @Test("A torrent is fetched whole from someone sharing it, and its file put with the others; downloads take turns")
    func torrentDownload() async throws {
        let fixture = try makeFixture()
        let shared = fixture.root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        let contents = Data((0 ..< (2 << 20)).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
        let source = shared.appendingPathComponent("Example.Show.S02E05.1080p.mkv")
        try contents.write(to: source)
        let torrentFile = fixture.root.appendingPathComponent("sample.torrent")
        let infoHash = try TorrentCreator.makeTorrent(forFile: source, output: torrentFile)
        let seeder = TorrentEngine(settings: .loopback(), directory: fixture.root.appendingPathComponent("seeder"))
        #expect(try await seeder.seed(torrentFile: torrentFile, dataDirectory: shared) == infoHash)
        await fixture.center.load()

        let torrent = try choice(#"{"infoHash": "\#(infoHash)", "name": "1080p", "description": "2 MB"}"#)
        let nobody = try choice(#"{"infoHash": "abababababababababababababababababababab", "name": "720p"}"#, position: 1)
        let first = try #require(fixture.center.add(torrent, for: episode))
        let second = try #require(fixture.center.add(nobody, for: film))
        #expect(fixture.center.pendingCount == 2)

        // Only the first is given to the engine; the second waits its turn.
        #expect(await eventually { await fixture.manager.isFetching(infoHash) })
        #expect(await !fixture.manager.isFetching("abababababababababababababababababababab"))
        #expect(fixture.center.item(for: film)?.activity == nil)
        #expect(await eventually { await seeder.listenPort != 0 })
        await fixture.manager.connect(infoHash, toPeerAt: "127.0.0.1", port: seeder.listenPort)

        #expect(await eventually { fixture.center.item(for: episode)?.stage == .finished })
        let file = try #require(fixture.center.finishedFile(for: episode))
        #expect(file.path == fixture.folder.appendingPathComponent("Example.Show.S02E05.1080p.mkv").path)
        #expect(try Data(contentsOf: file) == contents)
        #expect(fixture.center.item(for: episode)?.bytesTotal == Int64(contents.count))
        // Nothing of it is left where it was being fetched.
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent(".incomplete/\(infoHash)").path))
        #expect(first.id == fixture.center.item(for: episode)?.id)

        // Now the second has its turn. Nobody shares it: pausing lets go of the engine, and
        // removing it leaves nothing behind.
        #expect(await eventually { await fixture.manager.isFetching("abababababababababababababababababababab") })
        #expect(await eventually { fixture.center.item(for: film)?.activity == .findingPeers })
        fixture.center.pause(second.id)
        #expect(fixture.center.item(for: film)?.stage == .paused && fixture.center.pendingCount == 0)
        #expect(await eventually { await !fixture.manager.isFetching("abababababababababababababababababababab") })
        fixture.center.resume(second.id)
        #expect(await eventually { await fixture.manager.isFetching("abababababababababababababababababababab") })
        fixture.center.remove(second.id)
        #expect(fixture.center.item(for: film) == nil)
        #expect(await eventually { await !fixture.manager.isFetching("abababababababababababababababababababab") })
        await fixture.center.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent(".incomplete/abababababababababababababababababababab").path))

        await seeder.shutdown()
        await fixture.tearDown()
    }
}

/// A sample written by `Scripts/make-test-media.sh`.
private let downloadedSample = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "TestMedia/sdr-h264-1080p.mp4")

@MainActor
@Suite("Playing a download", .serialized)
struct DownloadPlaybackTests {
    @Test(
        "A downloaded file plays from this Mac, remembered as the video it is and not as a file",
        .enabled(if: FileManager.default.fileExists(atPath: downloadedSample.path), "run Scripts/make-test-media.sh first")
    )
    func playsTheFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downloads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = PlayerCoordinator(
            configuration: PlayerConfiguration(userAgent: "AppUITests/1.0", logSubsystem: "test.appui", videoOutput: .none, playsAudio: false),
            presentsWindow: false
        )
        let manager = StreamManager(settings: .loopback(), cache: StreamCache(directory: root.appendingPathComponent("cache")))
        let player = StreamPlayer(coordinator: coordinator, manager: manager)

        player.playFile(downloadedSample, for: episode)
        #expect(player.phase == .idle && player.nowPlaying == episode && player.nowPlayingChoice == nil)
        // No torrent is involved, so the engine is never started.
        #expect(player.activeTorrent == nil)
        let model = try #require(coordinator.player)
        #expect(model.source?.url == downloadedSample)
        #expect(model.currentMemoryKeys == episode.memoryKeys)
        #expect(model.title == episode.title)
        // Nothing is being fetched, so there is no percentage to show.
        #expect(model.waitingProgress == nil && model.waitingNote == nil)
        coordinator.closePlayer()
        await manager.shutdown()

        // A file that is not there says so, where the stream's messages go.
        player.playFile(URL(string: "ftp://example.com/film.mkv") ?? downloadedSample, for: episode)
        if case .failed = player.phase {} else {
            Issue.record("expected a message for a file that cannot be played, got \(player.phase)")
        }
    }
}
