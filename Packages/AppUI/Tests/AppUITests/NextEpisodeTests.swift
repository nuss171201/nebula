import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary
import PlayerKit
import StreamEngine
import Testing

/// A short sample written by `Scripts/make-test-media.sh`.
private let shortSample = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "TestMedia/sdr-h264-1080p.mp4")

@MainActor
@Suite(
    "Next-episode autoplay",
    .enabled(if: FileManager.default.fileExists(atPath: shortSample.path), "run Scripts/make-test-media.sh first"),
    .serialized
)
struct NextEpisodeTests {
    private struct Fixture {
        let harness: AddonHarness
        let server: StreamServer
        let coordinator: PlayerCoordinator
        let streamPlayer: StreamPlayer
        let controller: NextEpisodeController
        let center: LibraryCenter
        let manager: StreamManager
        /// The address each episode's stream is served at, by episode number.
        let addresses: [Int: URL]
        /// The stream add-on's id, as installed.
        let streamAddonID: String

        @MainActor
        func tearDown() async {
            coordinator.closePlayer()
            harness.server.stop()
            await server.stop()
            await manager.shutdown()
        }
    }

    private static let streamManifest = """
    {"id": "test.streams", "version": "1.0.0", "name": "Test Streams", "resources": ["stream"], "types": ["series"],
     "idPrefixes": ["tt"], "catalogs": []}
    """

    /// A series whose first season has two episodes, each with a stream in two qualities,
    /// served from this machine. `sleep` is how the countdown waits.
    private func makeFixture(
        secondEpisodeGroups: [String] = ["grp|720", "grp|1080"],
        sleep: @escaping NextEpisodeController.Sleep = { _ in }
    ) async throws -> Fixture {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/meta/series/tt0000042.json", with: .json(AddonFixtures.seriesMetaJSON()))
        harness.server.respond(to: "/streams/manifest.json", with: .json(Self.streamManifest))
        let server = StreamServer()
        try await server.start()
        let source = try #require(FileByteSource(url: shortSample))
        var addresses: [Int: URL] = [:]
        for episode in [1, 2] {
            addresses[episode] = try await server.publish(source, named: "episode-\(episode).mp4")
        }
        func streams(_ episode: Int, groups: [String]) -> String {
            let address = addresses[episode]?.absoluteString ?? ""
            let items = groups.map { group in
                #"{"url": "\#(address)", "name": "\#(group.hasSuffix("1080") ? "1080p" : "720p")", "behaviorHints": {"bingeGroup": "\#(group)"}}"#
            }
            return #"{"streams": [\#(items.joined(separator: ","))]}"#
        }
        harness.server.respond(to: "/streams/stream/series/tt0000042%3A1%3A1.json", with: .json(streams(1, groups: ["grp|720", "grp|1080"])))
        harness.server.respond(to: "/streams/stream/series/tt0000042%3A1%3A2.json", with: .json(streams(2, groups: secondEpisodeGroups)))
        harness.server.respond(to: "/streams/stream/series/tt0000042%3A2%3A1.json", with: .json(#"{"streams": []}"#))

        let history = WatchHistoryStore(database: harness.database)
        let center = LibraryCenter(library: LibraryStore(database: harness.database), history: history)
        let coordinator = PlayerCoordinator(
            configuration: PlayerConfiguration(userAgent: "AppUITests/1.0", logSubsystem: "test.appui", playsAudio: false),
            memory: LibraryPlayerMemory(
                store: PlaybackMemoryStore(database: harness.database),
                settings: SettingsStore(database: harness.database),
                history: history,
                historyChanged: { await center.noteChange() }
            ),
            presentsWindow: false
        )
        let manager = StreamManager(
            settings: .loopback(),
            cache: StreamCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("streams-\(UUID().uuidString)"))
        )
        let streamPlayer = StreamPlayer(coordinator: coordinator, manager: manager, library: center)
        let controller = NextEpisodeController(coordinator: coordinator, streamPlayer: streamPlayer, client: harness.client, sleep: sleep)
        let streamAddress = try harness.address("streams")
        let streamAddon = try await InstalledAddon(address: streamAddress, manifest: harness.client.manifest(at: streamAddress))
        try await controller.update(addons: [harness.installedAddon(), streamAddon])
        return Fixture(
            harness: harness, server: server, coordinator: coordinator, streamPlayer: streamPlayer,
            controller: controller, center: center, manager: manager, addresses: addresses, streamAddonID: streamAddon.id
        )
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

    /// Starts the first episode from its 1080p stream and runs it to its end.
    private func watchFirstEpisodeToTheEnd(_ fixture: Fixture) async throws -> PlayerModel {
        let address = try #require(fixture.addresses[1])
        let stream = try JSONDecoder().decode(
            StreamItem.self,
            from: Data(#"{"url": "\#(address.absoluteString)", "name": "1080p", "behaviorHints": {"bingeGroup": "grp|1080"}}"#.utf8)
        )
        let choice = StreamChoice(stream: stream, addonID: fixture.streamAddonID, addonName: "Test Streams", position: 1)
        let video = StreamVideo(
            type: .series, videoID: "tt0000042:1:1", titleID: "tt0000042", title: "Example Show — 1. Pilot",
            titleName: "Example Show", season: 1, episode: 1, episodeTitle: "Pilot"
        )
        fixture.streamPlayer.play(choice, for: video)
        let player = try #require(fixture.coordinator.player)
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
        player.seek(to: 9.6)
        #expect(await eventually { player.state.phase == .ended })
        return player
    }

    @Test("When an episode ends, the next is offered with a countdown and then starts from the same kind of stream")
    func autoplays() async throws {
        let fixture = try await makeFixture()
        let player = try await watchFirstEpisodeToTheEnd(fixture)
        await fixture.controller.waitForOffer()

        // The countdown (which does not really wait in this test) has run out: the second episode is on.
        #expect(await eventually { fixture.streamPlayer.nowPlaying?.videoID == "tt0000042:1:2" })
        #expect(player.upNext == nil)
        #expect(player.source?.url == fixture.addresses[2])
        #expect(player.title == "Example Show — 2. Second")
        // The 1080p stream was chosen again, not the first in the list.
        #expect(fixture.streamPlayer.nowPlayingChoice?.stream.behaviorHints.bingeGroup == "grp|1080")
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
        // The first episode counts as watched; the second is in the history as begun.
        #expect(await eventually { await fixture.center.entries(type: .series, titleID: "tt0000042")["tt0000042:1:1"]?.isWatched == true })
        #expect(await fixture.center.entries(type: .series, titleID: "tt0000042")["tt0000042:1:2"] != nil)
        await fixture.tearDown()
    }

    @Test("The offer counts down in the player, and can be taken at once")
    func acceptsEarly() async throws {
        // A countdown that never moves on by itself.
        let fixture = try await makeFixture(sleep: { _ in try await Task.sleep(for: .seconds(600)) })
        let player = try await watchFirstEpisodeToTheEnd(fixture)
        #expect(await eventually { player.upNext != nil })
        #expect(player.upNext == UpNextOffer(title: "S1 · E2 — Second", detail: "Example Show", secondsRemaining: 10))

        // "Play Now", as the card's button sends it.
        fixture.coordinator.perform(.acceptUpNext)
        #expect(player.upNext == nil)
        #expect(await eventually { fixture.streamPlayer.nowPlaying?.videoID == "tt0000042:1:2" })
        await fixture.tearDown()
    }

    @Test("Declining leaves the finished episode where it is; so does seeking back from the end")
    func declines() async throws {
        let fixture = try await makeFixture(sleep: { _ in try await Task.sleep(for: .seconds(600)) })
        let player = try await watchFirstEpisodeToTheEnd(fixture)
        #expect(await eventually { player.upNext != nil })

        fixture.coordinator.perform(.declineUpNext)
        #expect(player.upNext == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.streamPlayer.nowPlaying?.videoID == "tt0000042:1:1" && player.upNext == nil)
        // With no offer standing, the command is not handled, so Escape can do its other jobs.
        #expect(!fixture.coordinator.perform(.declineUpNext))

        // Going back and reaching the end again offers it again; going back withdraws it.
        player.seek(to: 5)
        #expect(await eventually { player.state.phase == .playing })
        // The player pauses on the last frame; it has to be running to reach the end again.
        player.setPaused(false)
        player.seek(to: 9.6)
        #expect(await eventually { player.upNext != nil })
        player.seek(to: 2)
        #expect(await eventually { player.upNext == nil })
        #expect(fixture.streamPlayer.nowPlaying?.videoID == "tt0000042:1:1")
        await fixture.tearDown()
    }

    @Test("Nothing is offered when the next episode has no stream like the last, or when autoplay is off")
    func noOffer() async throws {
        let different = try await makeFixture(secondEpisodeGroups: ["other|480"])
        let player = try await watchFirstEpisodeToTheEnd(different)
        await different.controller.waitForOffer()
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.upNext == nil && different.streamPlayer.nowPlaying?.videoID == "tt0000042:1:1")
        await different.tearDown()

        let off = try await makeFixture()
        off.controller.isEnabled = false
        let other = try await watchFirstEpisodeToTheEnd(off)
        try await Task.sleep(for: .milliseconds(300))
        #expect(other.upNext == nil && off.streamPlayer.nowPlaying?.videoID == "tt0000042:1:1")
        await off.tearDown()
    }
}
