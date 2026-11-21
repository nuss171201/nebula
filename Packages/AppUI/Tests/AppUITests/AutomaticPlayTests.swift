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
        player.startTimeout = (.milliseconds(500), .seconds(15))
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
