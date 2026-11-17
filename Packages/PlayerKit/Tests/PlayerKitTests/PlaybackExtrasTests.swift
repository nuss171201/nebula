import CoreGraphics
import Foundation
import ImageIO
@testable import PlayerKit
import Testing

@Suite("Screenshots, repeat and notices (pure)")
struct PlaybackExtrasTests {
    @Test("Screenshot names say what was playing and where", arguments: [
        ("multi-track.mkv", true, 2.4, "multi-track 0.02"),
        ("Episode 1.5", false, 3725, "Episode 1.5 1.02.05"),
        ("AC/DC: Live", false, 61, "AC-DC- Live 1.01"),
        ("  ", false, 0, "Screenshot 0.00"),
        (".hidden.mp4", true, 5, "hidden 0.05"),
    ])
    func screenshotNames(title: String, isFileName: Bool, position: Double, expected: String) {
        #expect(ScreenshotFile.baseName(title: title, isFileName: isFileName, position: position) == expected)
    }

    @Test("Very long titles are cut so the name stays usable")
    func longTitle() {
        let name = ScreenshotFile.baseName(title: String(repeating: "a", count: 400), isFileName: false, position: 0)
        #expect(name.count == 100 + " 0.00".count)
    }

    @Test("A screenshot never replaces an existing file")
    func freeNames() {
        let directory = URL(fileURLWithPath: "/shots")
        let taken: Set = ["/shots/Film 0.10.png", "/shots/Film 0.10 2.png"]
        #expect(ScreenshotFile.freeURL(baseName: "Film 0.10", in: directory) { taken.contains($0.path) }.path == "/shots/Film 0.10 3.png")
        #expect(ScreenshotFile.freeURL(baseName: "Film 0.11", in: directory) { taken.contains($0.path) }.path == "/shots/Film 0.11.png")
    }

    @Test("Repeat modes translate to the engine's two loop switches")
    func repeatModes() {
        #expect(RepeatMode.off.engineWrites == [EngineWrite("loop-file", .string("no")), EngineWrite("loop-playlist", .string("no"))])
        #expect(RepeatMode.one.engineWrites == [EngineWrite("loop-file", .string("inf")), EngineWrite("loop-playlist", .string("no"))])
        #expect(RepeatMode.all.engineWrites == [EngineWrite("loop-file", .string("no")), EngineWrite("loop-playlist", .string("inf"))])
    }
}

@MainActor
@Suite("Side panels")
struct SidePanelTests {
    @Test("Only one side panel is open at a time, and either keeps the controls up")
    func oneAtATime() async {
        let chrome = PlayerChromeModel(sleep: { _ in })
        chrome.playbackChanged(isPlaying: true)
        chrome.isQueueVisible = true
        #expect(chrome.isSidePanelVisible)
        await chrome.waitForPendingHide()
        #expect(chrome.isVisible)

        chrome.toggleSettingsPanel(.audio)
        #expect(chrome.isSettingsPanelVisible && !chrome.isQueueVisible)
        chrome.isQueueVisible = true
        #expect(chrome.isQueueVisible && !chrome.isSettingsPanelVisible)

        chrome.isQueueVisible = false
        #expect(!chrome.isSidePanelVisible)
        await chrome.waitForPendingHide()
        #expect(!chrome.isVisible)
    }
}

@MainActor
@Suite(
    "Screenshots, repeat, queue editing and notices through the engine",
    .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"),
    .serialized
)
struct PlaybackExtrasEngineTests {
    private let screenshots = FileManager.default.temporaryDirectory
        .appendingPathComponent("playerkit-tests-\(UUID().uuidString)", isDirectory: true)

    private func makePlayer(video: PlayerConfiguration.VideoOutput = .none) throws -> PlayerModel {
        try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: video,
            playsAudio: false,
            screenshotDirectory: screenshots
        ))
    }

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
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
    }

    @Test("Saves screenshots as PNG files named after the file, without overwriting")
    func savesScreenshots() async throws {
        let player = try makePlayer(video: .surface)
        defer {
            player.shutdown()
            try? FileManager.default.removeItem(at: screenshots)
        }
        #expect(await player.saveScreenshot(includingSubtitles: true) == nil)
        #expect(player.notice?.text == "Nothing to Capture")

        try await open(TestMedia.multiTrack, in: player)
        player.setPaused(true)
        player.seek(to: 2)
        #expect(await eventually { abs(player.state.position - 2) < 0.1 })

        let first = try #require(await player.saveScreenshot(includingSubtitles: false))
        #expect(first.lastPathComponent == "multi-track 0.02.png")
        #expect(first.deletingLastPathComponent().path == screenshots.path)
        #expect(player.notice?.text == "Screenshot Saved")
        let second = try #require(await player.saveScreenshot(includingSubtitles: false))
        #expect(second.lastPathComponent == "multi-track 0.02 2.png")

        let source = try #require(CGImageSourceCreateWithURL(first as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1280 && image.height == 720)
    }

    @Test("Repeat modes reach the engine, and repeating one file starts it again at its end")
    func repeats() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)

        player.repeatMode = .all
        #expect(await eventually { player.engineProperty("loop-playlist") == "inf" && player.engineProperty("loop-file") == "no" })
        player.repeatMode = .one
        #expect(await eventually { player.engineProperty("loop-file") == "inf" && player.engineProperty("loop-playlist") == "no" })

        player.seek(to: 9.6)
        #expect(await eventually { player.state.position > 9.5 })
        // Past the end it is back near the start, still playing the same file.
        #expect(await eventually { player.state.position < 2 && player.state.phase == .playing })
        #expect(player.title == "sdr-h264-1080p.mp4")
    }

    @Test("Queue entries can be removed and reordered without interrupting playback")
    func editsQueue() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        let sources = try [TestMedia.sdr, TestMedia.multiTrack, TestMedia.hdr].map { try PlayableSource(url: $0) }
        player.open(sources)
        #expect(await eventually { player.state.playlist.count == 3 && player.state.phase == .playing })
        player.setPaused(true)

        // The last entry to the front: "before the entry now at 0".
        player.moveQueueEntry(from: 2, toBefore: 0)
        #expect(await eventually {
            player.state.playlist.map(\.displayName) == ["hdr10-hevc-4k60.mkv", "sdr-h264-1080p.mp4", "multi-track.mkv"]
        })
        #expect(player.state.playlist.map(\.isCurrent) == [false, true, false])
        // The first to the end: "before the entry at count".
        player.moveQueueEntry(from: 0, toBefore: 3)
        #expect(await eventually {
            player.state.playlist.map(\.displayName) == ["sdr-h264-1080p.mp4", "multi-track.mkv", "hdr10-hevc-4k60.mkv"]
        })
        #expect(player.title == "sdr-h264-1080p.mp4")

        player.removeFromQueue(at: 1)
        #expect(await eventually { player.state.playlist.map(\.displayName) == ["sdr-h264-1080p.mp4", "hdr10-hevc-4k60.mkv"] })
        // Out of range: ignored.
        player.removeFromQueue(at: 7)
        player.moveQueueEntry(from: 5, toBefore: 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.state.playlist.count == 2)

        // Removing what is playing moves on to the next entry.
        player.removeFromQueue(at: 0)
        #expect(await eventually { player.title == "hdr10-hevc-4k60.mkv" && player.state.playlist.count == 1 })
    }

    @Test("Commands confirm themselves with a notice, and a newer notice replaces an older one")
    func notices() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.multiTrack, in: player)
        player.setPaused(true)
        #expect(player.notice == nil)

        player.perform(.speedUp)
        #expect(player.notice?.text == "Speed 1.25×")
        let first = try #require(player.notice)
        player.perform(.resetSpeed)
        #expect(player.notice?.text == "Speed 1×")
        // Dismissing the older notice leaves the newer one up.
        player.dismissNotice(first.id)
        #expect(player.notice?.text == "Speed 1×")

        player.perform(.changeVolumeBy(-15))
        #expect(player.notice?.text == "Volume 85 %")
        player.perform(.toggleMute)
        #expect(player.notice?.text == "Muted")
        player.perform(.shiftSubtitleDelay(-0.1))
        #expect(player.notice?.text == "Subtitle Delay −0.1 s")
        player.perform(.shiftAudioDelay(0.1))
        #expect(player.notice?.text == "Audio Delay +0.1 s")
        player.perform(.toggleSubtitles)
        #expect(player.notice?.text == "Subtitles Hidden")
        player.perform(.nextChapter)
        #expect(player.notice?.text == player.state.chapters[1].title)

        player.seek(to: 3)
        #expect(await eventually { abs(player.state.position - 3) < 0.1 })
        player.perform(.cycleABLoop)
        #expect(player.notice?.text == "Loop Start 0:03")
        player.perform(.cycleABLoop)
        #expect(player.notice?.text == "Loop Start 0:03")
        player.perform(.cycleABLoop)
        #expect(player.notice?.text == "Loop Start 0:03")

        let last = try #require(player.notice)
        player.dismissNotice(last.id)
        #expect(player.notice == nil)
    }

    @Test("Cycling tracks names the track that was chosen")
    func trackNotices() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.multiTrack, in: player)
        await player.waitForTrackSelection()
        #expect(await eventually { player.state.selectedTrack(of: .audio) != nil })

        let audio = player.state.tracks(of: .audio)
        let current = try #require(audio.firstIndex { $0.isSelected })
        player.perform(.cycleTrack(.audio))
        #expect(player.notice?.text == "Audio: " + audio[(current + 1) % audio.count].displayName())

        try await open(TestMedia.sdr, in: player)
        player.perform(.cycleTrack(.subtitle))
        #expect(player.notice?.text == "Subtitles: None in This File")
    }
}
