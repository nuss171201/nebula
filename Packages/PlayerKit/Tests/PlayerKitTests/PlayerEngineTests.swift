import AppKit
import Foundation
@testable import PlayerKit
import Testing

/// The sample files written by `Scripts/make-test-media.sh`.
enum TestMedia {
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent() // PlayerKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // PlayerKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repository root
        .appending(path: "TestMedia")

    static let sdr = directory.appending(path: "sdr-h264-1080p.mp4")
    static let hdr = directory.appending(path: "hdr10-hevc-4k60.mkv")
    static let multiTrack = directory.appending(path: "multi-track.mkv")

    static var isAvailable: Bool {
        [sdr, hdr, multiTrack].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Plays the generated sample files through the real engine. Audio is always discarded,
/// so running the tests never makes a sound. Skipped when the samples have not been generated.
@MainActor
@Suite("Playback engine", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct PlayerEngineTests {
    private func makePlayer(video: PlayerConfiguration.VideoOutput = .none) throws -> PlayerModel {
        try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: video,
            playsAudio: false
        ))
    }

    /// Polls until `condition` holds or the timeout passes; returns whether it held.
    private func eventually(within timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func open(_ url: URL, in player: PlayerModel) async throws {
        try player.open(PlayableSource(url: url))
        #expect(player.state.phase == .loading)
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
    }

    @Test("Opens a local file, reports its duration and title, and the playhead advances")
    func playsLocalFile() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)

        let duration = try #require(player.state.duration)
        #expect(abs(duration - 10) < 0.2)
        #expect(player.title == "sdr-h264-1080p.mp4")
        #expect(player.timeToFirstFrame != nil)

        let start = player.state.position
        #expect(await eventually { player.state.position > start + 0.5 })
        #expect(player.state.isAdvancing)
    }

    @Test("Pausing stops the playhead and resuming continues")
    func pauseAndResume() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)

        player.togglePause()
        #expect(await eventually { player.state.isPaused })
        // Let the last playhead update from before the pause arrive, then it must hold still.
        try await Task.sleep(for: .milliseconds(200))
        let held = player.state.position
        try await Task.sleep(for: .milliseconds(400))
        #expect(player.state.position == held)

        player.togglePause()
        #expect(await eventually { !player.state.isPaused && player.state.position > held + 0.2 })
    }

    @Test("Seeks to absolute positions and by relative steps, clamped to the file")
    func seeking() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)
        player.setPaused(true)
        #expect(await eventually { player.state.isPaused })

        player.seek(to: 7)
        #expect(await eventually { abs(player.state.position - 7) < 0.3 })

        player.seek(by: -5)
        #expect(await eventually { abs(player.state.position - 2) < 0.3 })

        player.scrubPosition = 6
        #expect(player.displayPosition == 6)
        player.commitScrub()
        #expect(player.scrubPosition == nil)
        #expect(await eventually { abs(player.state.position - 6) < 0.3 })

        player.seek(to: -50)
        #expect(await eventually { player.state.position < 0.3 })
    }

    @Test("Volume and mute are applied and stay in range")
    func volume() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)

        player.setVolume(35)
        #expect(await eventually { player.engineProperty("volume").flatMap(Double.init) == 35 })
        player.perform(.changeVolumeBy(-50))
        #expect(player.state.volume == 0)
        player.setVolume(250)
        #expect(player.state.volume == 100)

        player.toggleMute()
        #expect(await eventually { player.engineProperty("mute") == "yes" })
        // Turning the volume up from muted unmutes.
        player.setVolume(60)
        #expect(await eventually { player.engineProperty("mute") == "no" })
        #expect(!player.state.isMuted)
    }

    @Test("At the end the player holds the last frame, and Play starts over")
    func endOfFile() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)

        player.seek(to: 9.6)
        #expect(await eventually { player.state.phase == .ended })
        #expect(player.state.hasMedia)

        player.togglePause()
        #expect(await eventually { player.state.phase == .playing && player.state.position < 2 && !player.state.isPaused })
    }

    @Test("A file that does not exist fails with a readable message")
    func missingFile() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try player.open(PlayableSource(url: TestMedia.directory.appending(path: "does-not-exist.mp4")))
        #expect(await eventually { player.state.phase == .failed("The file or address could not be opened.") })

        // The player is still usable afterwards.
        try await open(TestMedia.sdr, in: player)
    }

    @Test("A file that is not media fails as an unknown format")
    func notMedia() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        let textFile = FileManager.default.temporaryDirectory.appending(path: "PlayerKitTests-\(UUID().uuidString).mp4")
        try Data("this is not a video".utf8).write(to: textFile)
        defer { try? FileManager.default.removeItem(at: textFile) }

        try player.open(PlayableSource(url: textFile))
        #expect(await eventually { player.state.phase == .failed("This file is not in a format that can be played.") })
    }

    @Test("Opening a second file replaces the first")
    func replacesFile() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)
        try await open(TestMedia.multiTrack, in: player)
        #expect(player.title == "multi-track.mkv")
        let duration = try #require(player.state.duration)
        #expect(abs(duration - 20) < 0.3)
    }

    @Test("Renders 4K HDR into the Metal surface with hardware decoding")
    func rendersToSurface() async throws {
        let player = try makePlayer(video: .surface)
        defer { player.shutdown() }
        let surface = try #require(player.surface)
        // Never shown: the engine renders into the layer whether or not the window is on screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = surface

        try await open(TestMedia.hdr, in: player)
        #expect(player.state.videoSize == CGSize(width: 3840, height: 2160))
        #expect(await eventually { player.state.hardwareDecoder == "videotoolbox" })
        #expect(player.engineProperty("current-vo") == "gpu-next")
        #expect(player.engineProperty("video-params/hw-pixelformat") == "p010")

        let start = player.state.position
        #expect(await eventually { player.state.position > start + 1 })
        let dropped = player.engineProperty("frame-drop-count").flatMap(Int.init) ?? -1
        #expect(dropped >= 0 && dropped < 30)

        // The layer follows the view through a resize.
        window.setContentSize(NSSize(width: 640, height: 360))
        let scale = surface.metalLayer.contentsScale
        #expect(surface.metalLayer.drawableSize == CGSize(width: 640 * scale, height: 360 * scale))
        let afterResize = player.state.position
        #expect(await eventually { player.state.position > afterResize + 0.5 })
    }

    @Test("Shutting down ends the event stream and reports once")
    func shutdown() async throws {
        let player = try makePlayer()
        try await open(TestMedia.sdr, in: player)

        var shutdowns = 0
        player.onShutdown = { shutdowns += 1 }
        player.shutdown()
        player.shutdown()
        #expect(await eventually { shutdowns == 1 })
        #expect(player.state.phase == .idle)

        // Calls after shutdown are ignored rather than crashing.
        player.togglePause()
        player.seek(to: 3)
        try await Task.sleep(for: .milliseconds(100))
        #expect(shutdowns == 1)
    }
}
