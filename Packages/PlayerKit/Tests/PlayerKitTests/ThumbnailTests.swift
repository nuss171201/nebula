import CoreGraphics
import Foundation
@testable import PlayerKit
import Testing

@Suite("Seek bar thumbnails", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"))
struct ThumbnailGeneratorTests {
    @Test("Produces small frames at the video's proportions, different at different times")
    func generates() async throws {
        let generator = try ThumbnailGenerator(source: PlayableSource(url: TestMedia.sdr), userAgent: "PlayerKitTests/1.0")
        defer { generator.shutDown() }

        let start = try #require(await generator.thumbnail(at: 0))
        #expect(start.width == 320 && start.height == 180)

        // The sample has a keyframe every 250 frames (8.3 s), so 9 s lands on the second one.
        let later = try #require(await generator.thumbnail(at: 9))
        #expect(FrameImage.pngData(start) != FrameImage.pngData(later))

        // Asking again for the first keyframe gives the first picture again.
        let again = try #require(await generator.thumbnail(at: 0.5))
        #expect(FrameImage.pngData(again) == FrameImage.pngData(start))
    }

    @Test("Handles 4K HDR and unusual shapes without the playing engine")
    func otherSources() async throws {
        let hdr = try ThumbnailGenerator(source: PlayableSource(url: TestMedia.hdr), userAgent: "PlayerKitTests/1.0", pixelWidth: 240)
        defer { hdr.shutDown() }
        let frame = try #require(await hdr.thumbnail(at: 3))
        #expect(frame.width == 240 && frame.height == 136)
    }

    @Test("Returns nothing for a file that is not video, and after shutdown")
    func failures() async throws {
        let missing = try ThumbnailGenerator(
            source: PlayableSource(url: TestMedia.directory.appending(path: "missing.mkv")),
            userAgent: "PlayerKitTests/1.0"
        )
        #expect(await missing.thumbnail(at: 1) == nil)
        #expect(await missing.thumbnail(at: 2) == nil)

        let generator = try ThumbnailGenerator(source: PlayableSource(url: TestMedia.sdr), userAgent: "PlayerKitTests/1.0")
        #expect(await generator.thumbnail(at: 1) != nil)
        generator.shutDown()
        #expect(await generator.thumbnail(at: 1) == nil)
    }
}

@Suite("Seek bar geometry")
struct SeekBarGeometryTests {
    @Test("Positions along the bar map to times and back, clamped to the file")
    func timeMapping() {
        #expect(SeekBarGeometry.time(atX: 150, width: 600, duration: 120) == 30)
        #expect(SeekBarGeometry.time(atX: -20, width: 600, duration: 120) == 0)
        #expect(SeekBarGeometry.time(atX: 900, width: 600, duration: 120) == 120)
        #expect(SeekBarGeometry.time(atX: 10, width: 0, duration: 120) == 0)
        #expect(SeekBarGeometry.x(for: 30, width: 600, duration: 120) == 150)
        #expect(SeekBarGeometry.x(for: 500, width: 600, duration: 120) == 600)
        #expect(SeekBarGeometry.x(for: 10, width: 600, duration: 0) == 0)
    }

    @Test("The preview follows the pointer but stays within the bar")
    func previewPlacement() {
        #expect(SeekBarGeometry.previewOffset(centredAt: 300, previewWidth: 176, barWidth: 600) == 212)
        #expect(SeekBarGeometry.previewOffset(centredAt: 10, previewWidth: 176, barWidth: 600) == 0)
        #expect(SeekBarGeometry.previewOffset(centredAt: 595, previewWidth: 176, barWidth: 600) == 424)
        #expect(SeekBarGeometry.previewOffset(centredAt: 50, previewWidth: 176, barWidth: 100) == 0)
    }

    @Test("A position belongs to the last chapter that starts at or before it")
    func chapterLookup() {
        var state = PlaybackState()
        #expect(state.chapter(at: 10) == nil)
        state.apply(.property(.chapters([
            MediaChapter(index: 0, title: "Opening", start: 0),
            MediaChapter(index: 1, title: "Middle", start: 5),
            MediaChapter(index: 2, title: "Ending", start: 12),
        ])))
        #expect(state.chapter(at: 0)?.title == "Opening")
        #expect(state.chapter(at: 4.99)?.title == "Opening")
        #expect(state.chapter(at: 5)?.title == "Middle")
        #expect(state.chapter(at: 100)?.title == "Ending")
    }

    @Test("Previews are spaced at least a second apart, and no more than 150 per file")
    func previewSteps() {
        #expect(PlayerModel.thumbnailStep(duration: 20) == 1)
        #expect(PlayerModel.thumbnailStep(duration: 150) == 1)
        #expect(PlayerModel.thumbnailStep(duration: 7200) == 48)
    }
}

@MainActor
@Suite("Seek bar previews through the player", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct PlayerThumbnailTests {
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

    @Test("The player hands out previews, caches them per step, and drops them with the file")
    func previews() async throws {
        let player = try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .none,
            playsAudio: false
        ))
        defer { player.shutdown() }
        #expect(!player.canPreviewFrames)
        #expect(await player.thumbnail(at: 1) == nil)

        try player.open(PlayableSource(url: TestMedia.sdr))
        // The seek bar asks again when this turns true; a file being open is not enough on its own.
        #expect(await eventually { player.canPreviewFrames })

        let first = try #require(await player.thumbnail(at: 9.2))
        #expect(first.width == 320)
        // The same one-second step is served from the cache: the very same image object.
        let again = try #require(await player.thumbnail(at: 9.7))
        #expect(first === again)
        #expect(player.thumbnailCache.count == 1)

        try player.open(PlayableSource(url: TestMedia.multiTrack))
        #expect(await eventually { player.state.hasShownFirstFrame && player.title == "multi-track.mkv" })
        #expect(player.thumbnailCache.isEmpty)
        let other = try #require(await player.thumbnail(at: 2))
        #expect(other.width == 320 && other.height == 180)
    }

    @Test("Reports how much of the file is buffered")
    func buffered() async throws {
        let player = try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .none,
            playsAudio: false
        ))
        defer { player.shutdown() }
        #expect(player.bufferedFraction == nil)
        try player.open(PlayableSource(url: TestMedia.sdr))
        // A small local file is read ahead completely within moments.
        #expect(await eventually { (player.bufferedFraction ?? 0) > 0.5 })
        #expect((player.bufferedFraction ?? 2) <= 1)
    }
}
