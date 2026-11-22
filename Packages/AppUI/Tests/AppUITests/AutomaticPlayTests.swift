@testable import AppUI
import Foundation
import MediaCore
import PlayerKit
import StreamEngine
import Testing

/// A sample written by `Scripts/make-test-media.sh`.
private let streamSample = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "TestMedia/sdr-h264-1080p.mp4")

private func choice(_ json: String, position: Int) throws -> StreamChoice {
    let stream = try JSONDecoder().decode(StreamItem.self, from: Data(json.utf8))
    return StreamChoice(stream: stream, addonID: "a", addonName: "Add-on A", position: position)
}

@MainActor
@Suite("Play, choosing for the user", .serialized)
struct AutomaticPlayTests {
    private let video = StreamVideo(type: .movie, videoID: "tt0000001", titleID: "tt0000001", title: "Example Film")

    private func makeCoordinator() -> PlayerCoordinator {
        PlayerCoordinator(
            configuration: PlayerConfiguration(userAgent: "AppUITests/1.0", logSubsystem: "test.appui", videoOutput: .none, playsAudio: false),
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

    /// A loopback server with the sample published at one address, and a second address that answers "not found".
    private func makeServer() async throws -> (server: StreamServer, good: URL, gone: URL) {
        let server = StreamServer()
        try await server.start()
        let source = try #require(FileByteSource(url: streamSample))
        let good = try await server.publish(source, named: "film.mp4")
        let gone = try await server.publish(source, named: "gone.mp4")
        await server.withdraw(gone)
        return (server, good, gone)
    }

    @Test(
        "Play starts the most suitable stream; if it will not start, the next one is tried, and the one that plays is reported",
        .enabled(if: FileManager.default.fileExists(atPath: streamSample.path), "run Scripts/make-test-media.sh first")
    )
    func automaticPlay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, good, gone) = try await makeServer()
        let manager = makeManager(root: root)
        let coordinator = makeCoordinator()
        let player = StreamPlayer(coordinator: coordinator, manager: manager)
        // A torrent nobody shares is given half a second, not half a minute.
        player.patience.torrent = StartPatience(quiet: .milliseconds(500), limit: .seconds(60))
        let lonely = try choice(#"{"infoHash": "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", "name": "4K"}"#, position: 0)
        let missing = try choice(#"{"url": "\#(gone.absoluteString)", "name": "1080p"}"#, position: 1)
        let working = try choice(#"{"url": "\#(good.absoluteString)", "name": "720p"}"#, position: 2)
        var started: [StreamChoice] = []

        player.playAutomatically([lonely, missing, working], for: video) { started.append($0) }
        await player.waitForAutomaticPlay()

        #expect(started == [working])
        #expect(player.phase == .idle)
        #expect(coordinator.player?.source?.url == good)
        #expect(coordinator.player?.state.phase == .playing)
        #expect(player.nowPlayingChoice == working)
        // The torrent that was given up on is not left running.
        #expect(await eventually { await !manager.isFetching("cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd") })

        coordinator.closePlayer()
        await server.stop()
        await manager.shutdown()
    }

    @Test(
        "When nothing tried will start, Play says so and leaves no player open; at most three are tried",
        .enabled(if: FileManager.default.fileExists(atPath: streamSample.path), "run Scripts/make-test-media.sh first")
    )
    func automaticPlayGivesUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, good, gone) = try await makeServer()
        let manager = makeManager(root: root)
        let coordinator = makeCoordinator()
        let player = StreamPlayer(coordinator: coordinator, manager: manager)
        let missing = try (0 ..< 3).map { try choice(#"{"url": "\#(gone.absoluteString)?n=\#($0)", "name": "1080p"}"#, position: $0) }
        let working = try choice(#"{"url": "\#(good.absoluteString)", "name": "720p"}"#, position: 3)
        var started: [StreamChoice] = []

        player.playAutomatically(missing + [working], for: video) { started.append($0) }
        await player.waitForAutomaticPlay()
        #expect(started.isEmpty)
        #expect(player.phase == .failed(title: video.title, message: "None of the 3 streams tried would start. Choose one from the list."))
        #expect(!coordinator.isPlayerOpen)

        player.playAutomatically([], for: video)
        #expect(player.phase == .failed(title: video.title, message: "Nothing here can be played by itself. Choose a stream from the list."))
        await server.stop()
        await manager.shutdown()
    }

    @Test(
        "A torrent that is arriving, however slowly, is not given up on for the next stream",
        .enabled(if: FileManager.default.fileExists(atPath: streamSample.path), "run Scripts/make-test-media.sh first")
    )
    func staysWithWhatIsArriving() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)")
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = shared.appendingPathComponent("Example.Film.1080p.mp4")
        try FileManager.default.copyItem(at: streamSample, to: file)
        let torrentFile = root.appendingPathComponent("sample.torrent")
        let infoHash = try TorrentCreator.makeTorrent(forFile: file, output: torrentFile)
        // Someone on this machine shares the sample, slowly: its first picture takes longer
        // than Play waits in silence.
        var slow = TorrentEngineSettings.loopback()
        slow.uploadRateLimit = Self.seedRate
        slow.limitsPeersOnThisMachine = true
        let seeder = TorrentEngine(settings: slow, directory: root.appendingPathComponent("seeder"))
        #expect(try await seeder.seed(torrentFile: torrentFile, dataDirectory: shared) == infoHash)
        let (server, good, _) = try await makeServer()
        let manager = makeManager(root: root)
        let coordinator = makeCoordinator()
        let player = StreamPlayer(coordinator: coordinator, manager: manager)
        // Long enough for the two engines to meet, which the other tests give five seconds too.
        let quiet = Duration.seconds(5)
        player.patience.torrent = StartPatience(quiet: quiet, limit: .seconds(600))
        player.arrivalInterval = .milliseconds(100)
        let arriving = try choice(#"{"infoHash": "\#(infoHash)", "name": "4K"}"#, position: 0)
        let other = try choice(#"{"url": "\#(good.absoluteString)", "name": "720p"}"#, position: 1)
        var started: [StreamChoice] = []

        let began = ContinuousClock.now
        player.playAutomatically([arriving, other], for: video) { started.append($0) }
        #expect(await eventually { await manager.isFetching(infoHash) })
        #expect(await eventually { await seeder.listenPort != 0 })
        await manager.connect(infoHash, toPeerAt: "127.0.0.1", port: seeder.listenPort)
        await player.waitForAutomaticPlay()
        let took = ContinuousClock.now - began

        #expect(started == [arriving])
        #expect(player.activeTorrent == infoHash)
        // Otherwise this showed nothing: the stream would have started in time anyway.
        #expect(took > quiet + .seconds(1), "the first picture came after \(took)")

        coordinator.closePlayer()
        await server.stop()
        await manager.shutdown()
        await seeder.shutdown()
    }

    /// Bytes a second the slow sharer gives.
    private static let seedRate = 100_000

    @Test("Cancelling while Play is looking stops it there: nothing else is tried")
    func automaticPlayCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        let coordinator = makeCoordinator()
        let player = StreamPlayer(coordinator: coordinator, manager: manager)
        let lonely = try choice(#"{"infoHash": "efefefefefefefefefefefefefefefefefefefef", "name": "4K"}"#, position: 0)
        let other = try choice(#"{"infoHash": "0101010101010101010101010101010101010101", "name": "1080p"}"#, position: 1)
        var started: [StreamChoice] = []

        player.playAutomatically([lonely, other], for: video) { started.append($0) }
        #expect(await eventually { await manager.isFetching("efefefefefefefefefefefefefefefefefefefef") })
        player.cancel()
        await player.waitForAutomaticPlay()
        #expect(player.phase == .idle && started.isEmpty)
        #expect(await eventually { await !manager.isFetching("efefefefefefefefefefefefefefefefefefefef") })
        #expect(await !manager.isFetching("0101010101010101010101010101010101010101"))
        #expect(!coordinator.isPlayerOpen)
        await manager.shutdown()
    }
}

@Suite("How long Play stays with a stream")
struct StartPatienceTests {
    private let patience = StartPatience(quiet: .seconds(30), limit: .seconds(180))

    @Test("Nothing arriving for the quiet time ends it, whether or not there is another to try", arguments: [true, false])
    func silence(othersToTry: Bool) {
        #expect(!patience.isUp(waited: .seconds(29), sinceArrival: nil, secondsLeft: nil, othersToTry: othersToTry))
        #expect(patience.isUp(waited: .seconds(30), sinceArrival: nil, secondsLeft: nil, othersToTry: othersToTry))
        #expect(!patience.isUp(waited: .seconds(100), sinceArrival: .seconds(5), secondsLeft: nil, othersToTry: othersToTry))
        #expect(patience.isUp(waited: .seconds(100), sinceArrival: .seconds(31), secondsLeft: nil, othersToTry: othersToTry))
    }

    @Test("What is arriving is waited for: to the limit when another could be tried, and without one when not")
    func arriving() {
        #expect(!patience.isUp(waited: .seconds(120), sinceArrival: .seconds(1), secondsLeft: 20, othersToTry: true))
        #expect(patience.isUp(waited: .seconds(180), sinceArrival: .seconds(1), secondsLeft: 20, othersToTry: true))
        #expect(!patience.isUp(waited: .seconds(600), sinceArrival: .seconds(1), secondsLeft: 20, othersToTry: false))
    }

    @Test("A trickle that cannot make the limit is left once the quiet time has passed, if another could be tried")
    func trickle() {
        #expect(!patience.isUp(waited: .seconds(20), sinceArrival: .seconds(1), secondsLeft: 900, othersToTry: true))
        #expect(patience.isUp(waited: .seconds(30), sinceArrival: .seconds(1), secondsLeft: 900, othersToTry: true))
        #expect(!patience.isUp(waited: .seconds(30), sinceArrival: .seconds(1), secondsLeft: 140, othersToTry: true))
        #expect(!patience.isUp(waited: .seconds(30), sinceArrival: .seconds(1), secondsLeft: 900, othersToTry: false))
    }

    @Test("Until its first picture a video is being waited for, though the engine no longer calls itself busy")
    func waiting() {
        var state = PlaybackState()
        state.phase = .loading
        #expect(StreamPlayer.isWaiting(state))
        state.phase = .playing
        #expect(StreamPlayer.isWaiting(state))
        state.hasShownFirstFrame = true
        #expect(!StreamPlayer.isWaiting(state))
        state.isWaitingForData = true
        #expect(StreamPlayer.isWaiting(state))
    }

    @Test("The time a web address gets is simply a time")
    func direct() {
        #expect(!StartPatience.direct.isUp(waited: .seconds(19), sinceArrival: nil, secondsLeft: nil, othersToTry: true))
        #expect(StartPatience.direct.isUp(waited: .seconds(20), sinceArrival: nil, secondsLeft: nil, othersToTry: false))
    }

    @Test("Signs of arrival: more bytes are a sign, the same bytes are not, and the time left follows the better of rate and pace")
    func signs() {
        let start = ContinuousClock.now
        var signs = ArrivalSigns()
        #expect(signs.lastArrival == nil && signs.secondsLeft == nil)
        signs.noteDescription(at: start)
        #expect(signs.lastArrival == start)

        signs.note(ArrivalProgress(bytesDone: 0, bytesWanted: 10_000_000), rate: 0, at: start + .seconds(1))
        #expect(signs.lastArrival == start && signs.secondsLeft == nil)
        signs.note(ArrivalProgress(bytesDone: 1_000_000, bytesWanted: 10_000_000), rate: 100_000, at: start + .seconds(3))
        #expect(signs.lastArrival == start + .seconds(3))
        // Pace so far: a megabyte in two seconds, which beats the rate of this instant.
        #expect(signs.secondsLeft == 18)
        signs.note(ArrivalProgress(bytesDone: 1_000_000, bytesWanted: 10_000_000), rate: 3_000_000, at: start + .seconds(5))
        #expect(signs.lastArrival == start + .seconds(3))
        #expect(signs.secondsLeft == 3)
        // Nothing waited for at this instant: what was known stays.
        signs.note(nil, rate: 0, at: start + .seconds(6))
        #expect(signs.secondsLeft == 3)
        // The engine counts anew after a stall: fewer bytes are not an arrival, and the pace starts again.
        signs.note(ArrivalProgress(bytesDone: 0, bytesWanted: 4_000_000), rate: 0, at: start + .seconds(8))
        #expect(signs.lastArrival == start + .seconds(3) && signs.secondsLeft == nil)
    }
}
