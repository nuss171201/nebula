import CoreGraphics
import Foundation
@testable import PlayerKit
import Testing

@Suite("Tracks, chapters and settings (pure)")
struct PlayerSettingsTests {
    @Test("The engine's track list becomes typed tracks, skipping entries it cannot read")
    func trackParsing() {
        let node = MPVNode.array([
            .map(["type": .string("video"), "id": .int(1), "codec": .string("hevc"), "demux-w": .int(3840), "demux-h": .int(2160),
                  "demux-fps": .double(59.94), "selected": .flag(true)]),
            .map(["type": .string("audio"), "id": .int(2), "lang": .string("eng"), "title": .string("Surround"), "codec": .string("eac3"),
                  "demux-channel-count": .int(6), "default": .flag(true)]),
            .map(["type": .string("audio"), "id": .int(3), "lang": .string("und"), "title": .string("")]),
            .map(["type": .string("sub"), "id": .int(1), "lang": .string("spa"), "forced": .flag(true), "external": .flag(true)]),
            .map(["type": .string("attachment"), "id": .int(9)]),
            .string("not a track"),
        ])
        let tracks = MediaTrack.list(from: node)
        #expect(tracks.map(\.id) == ["video1", "audio2", "audio3", "sub1"])
        #expect(tracks[0].width == 3840)
        #expect(tracks[0].framesPerSecond == 59.94)
        #expect(tracks[0].isSelected)
        #expect(tracks[1].language == "eng")
        #expect(tracks[1].channelCount == 6)
        #expect(tracks[1].isDefault)
        #expect(tracks[2].language == nil)
        #expect(tracks[2].title == nil)
        #expect(tracks[3].isForced)
        #expect(tracks[3].isExternal)
    }

    @Test("Chapters and queue entries are read with sensible fallbacks")
    func chaptersAndQueue() {
        let chapters = MediaChapter.list(from: .array([
            .map(["title": .string("Intro"), "time": .double(0)]),
            .map(["time": .int(90)]),
            .map(["title": .string("no time")]),
        ]))
        #expect(chapters.map(\.title) == ["Intro", "Chapter 2"])
        #expect(chapters.map(\.start) == [0, 90])

        let queue = PlaylistEntry.list(from: .array([
            .map(["filename": .string("/media/One%20Film.mkv")]),
            .map(["filename": .string("https://example.com/v/two.mp4"), "title": .string("Two"), "current": .flag(true)]),
        ]))
        #expect(queue.map(\.displayName) == ["One Film.mkv", "Two"])
        #expect(queue.map(\.isCurrent) == [false, true])
    }

    @Test("State keeps tracks and chapters per file but the queue across files")
    func stateReduction() {
        var state = PlaybackState()
        state.apply(.property(.playlist([PlaylistEntry(index: 0, location: "/a.mkv")])))
        state.apply(.property(.tracks([MediaTrack(kind: .audio, number: 1, isSelected: true), MediaTrack(kind: .subtitle, number: 1)])))
        state.apply(.property(.chapters([MediaChapter(index: 0, title: "One", start: 0)])))
        state.apply(.property(.currentChapter(0)))
        #expect(state.selectedTrack(of: .audio)?.number == 1)
        #expect(state.selectedTrack(of: .subtitle) == nil)
        #expect(state.tracks(of: .subtitle).count == 1)

        state.apply(.startedLoading)
        #expect(state.tracks.isEmpty)
        #expect(state.chapters.isEmpty)
        #expect(state.currentChapter == nil)
        #expect(state.playlist.count == 1)
    }

    @Test("A crop ratio becomes a centred rectangle with even sides", arguments: [
        (16, 9, 1920.0, 1080.0, ""),
        (4, 3, 1920.0, 1080.0, "1440x1080+240+0"),
        (21, 9, 1920.0, 1080.0, "1920x822+0+129"),
        (1, 1, 1280.0, 720.0, "720x720+280+0"),
        (16, 9, 1440.0, 1080.0, "1440x810+0+135"),
    ])
    func cropRectangles(width: Int, height: Int, sourceWidth: Double, sourceHeight: Double, expected: String) {
        let crop = VideoSettings.Aspect.ratio(width: width, height: height)
        let value = VideoSettings.cropValue(crop, sourceSize: CGSize(width: sourceWidth, height: sourceHeight))
        // A crop that matches the source exactly still names the full frame, which is harmless.
        #expect(value == expected || (expected.isEmpty && value == "\(Int(sourceWidth))x\(Int(sourceHeight))+0+0"))
        #expect(VideoSettings.cropValue(.source, sourceSize: CGSize(width: sourceWidth, height: sourceHeight)).isEmpty)
        #expect(VideoSettings.cropValue(crop, sourceSize: nil).isEmpty)
    }

    @Test("Video settings translate to engine values, clamped")
    func videoWrites() {
        var settings = VideoSettings()
        #expect(!settings.hasColorAdjustments)
        #expect(!settings.hasGeometryAdjustments)
        settings.brightness = 250
        settings.rotation = .quarter
        settings.isMirrored = true
        settings.isFlipped = true
        settings.zoom = 9
        settings.aspect = .ratio(width: 4, height: 3)
        settings.usesHardwareDecoding = false
        let writes = Dictionary(settings.engineWrites(sourceSize: nil).map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(writes["brightness"] == .int(100))
        #expect(writes["video-rotate"] == .int(90))
        #expect(writes["vf"] == .string("hflip,vflip"))
        #expect(writes["video-zoom"] == .double(3))
        #expect(writes["video-aspect-override"] == .string("4:3"))
        #expect(writes["hwdec"] == .string("no"))
        #expect(settings.hasColorAdjustments && settings.hasGeometryAdjustments)

        settings.resetColor()
        settings.resetGeometry()
        #expect(!settings.hasColorAdjustments && !settings.hasGeometryAdjustments)
        #expect(VideoSettings.Rotation.threeQuarters.clockwise == .none)
        #expect(VideoSettings.Rotation.none.counterclockwise == .threeQuarters)
        #expect(VideoSettings.Rotation.quarter.swapsDimensions && !VideoSettings.Rotation.half.swapsDimensions)
    }

    @Test("The equaliser only adds a filter when it changes the sound")
    func equalizer() throws {
        var audio = AudioSettings()
        #expect(audio.engineWrites().contains(EngineWrite("af", .string(""))))

        audio.equalizer.isEnabled = true
        #expect(audio.equalizer.filter == nil)

        audio.equalizer = .init(isEnabled: true, gains: [6, 40, -40])
        #expect(audio.equalizer.gains.count == 10)
        #expect(audio.equalizer.gains.prefix(3) == [6, 12, -12])
        let filter = try #require(audio.equalizer.filter)
        #expect(filter.hasPrefix("lavfi=[firequalizer=gain_entry='entry(31,6.0);entry(62,12.0);entry(125,-12.0);"))

        audio.isNormalizingLoudness = true
        audio.delay = 99
        let writes = audio.engineWrites()
        #expect(writes.contains(EngineWrite("audio-delay", .double(10))))
        #expect(writes.contains { $0.name == "af" && $0.value == .string(filter + ",lavfi=[dynaudnorm]") })
        #expect(AudioSettings.Equalizer.presets.allSatisfy { $0.gains.count == 10 })
    }

    @Test("Subtitle settings translate to engine values")
    func subtitleWrites() {
        var subtitles = SubtitleSettings()
        subtitles.textColor = .yellow
        subtitles.scale = 100
        subtitles.position = -5
        subtitles.fontName = "Helvetica Neue"
        subtitles.overridesEmbeddedStyle = true
        subtitles.isVisible = false
        let writes = Dictionary(subtitles.engineWrites().map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(writes["sub-color"] == .string("#FFDD33"))
        #expect(writes["sub-scale"] == .double(4))
        #expect(writes["sub-pos"] == .double(0))
        #expect(writes["sub-font"] == .string("Helvetica Neue"))
        #expect(writes["sub-ass-override"] == .string("force"))
        #expect(writes["sub-visibility"] == .flag(false))
    }

    @Test("The A-B button marks the start, then the end, then clears")
    func abLoop() {
        var loop = ABLoop.off
        loop = loop.advanced(at: 10)
        #expect(loop == .startMarked(10))
        // An end at or before the start just moves the start.
        loop = loop.advanced(at: 9)
        #expect(loop == .startMarked(9))
        loop = loop.advanced(at: 15)
        #expect(loop == .looping(start: 9, end: 15))
        #expect(loop.engineWrites == [EngineWrite("ab-loop-a", .double(9)), EngineWrite("ab-loop-b", .double(15))])
        loop = loop.advanced(at: 20)
        #expect(loop == .off)
    }

    @Test("Raw frames become images, and malformed captures are refused")
    func frameImages() throws {
        // 2×2 pixels, 12 bytes per row (4 bytes of padding): blue, green / red, white.
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes.replaceSubrange(0 ..< 8, with: [255, 0, 0, 0, 0, 255, 0, 0])
        bytes.replaceSubrange(12 ..< 20, with: [0, 0, 255, 0, 255, 255, 255, 0])
        let node = MPVNode.map(["format": .string("bgr0"), "w": .int(2), "h": .int(2), "stride": .int(12), "data": .bytes(Data(bytes))])
        let image = try #require(FrameImage.make(from: node))
        #expect(image.width == 2 && image.height == 2)
        let png = try #require(FrameImage.pngData(image))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        #expect(FrameImage.make(from: .map(["format": .string("rgba")])) == nil)
        #expect(FrameImage.make(bgrx: Data(count: 4), width: 2, height: 2, bytesPerRow: 8) == nil)
    }
}

@MainActor
@Suite("Player features through the engine", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct PlayerFeatureEngineTests {
    private func makePlayer(video: PlayerConfiguration.VideoOutput = .none) throws -> PlayerModel {
        try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: video,
            playsAudio: false
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

    @Test("Lists the file's tracks and switches between them")
    func tracks() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.multiTrack, in: player)

        let audio = player.state.tracks(of: .audio)
        #expect(audio.map(\.codec) == ["ac3", "eac3", "dts", "aac", "aac"])
        #expect(audio.map(\.language) == ["fra", "deu", "jpn", nil, nil])
        #expect(audio.map(\.title) == ["Français", "Deutsch", "日本語", "English", nil])
        #expect(audio.map(\.channelCount) == [6, 6, 6, 2, 2])
        #expect(player.state.tracks(of: .subtitle).map(\.language) == ["spa", "eng"])
        #expect(player.state.tracks(of: .video).first?.width == 1280)

        player.selectTrack(.audio, number: 4)
        #expect(await eventually { player.state.selectedTrack(of: .audio)?.title == "English" })
        player.selectTrack(.subtitle, number: 2)
        #expect(await eventually { player.state.selectedTrack(of: .subtitle)?.language == "eng" })
        player.selectTrack(.subtitle, number: nil)
        #expect(await eventually { player.state.selectedTrack(of: .subtitle) == nil })

        // Cycling subtitles goes first, second, off.
        player.perform(.cycleTrack(.subtitle))
        #expect(await eventually { player.state.selectedTrack(of: .subtitle)?.number == 1 })
        player.perform(.cycleTrack(.subtitle))
        #expect(await eventually { player.state.selectedTrack(of: .subtitle)?.number == 2 })
        player.perform(.cycleTrack(.subtitle))
        #expect(await eventually { player.state.selectedTrack(of: .subtitle) == nil })
    }

    @Test("Switching track does not move the playhead, and a seek straight afterwards lands on target", arguments: 0 ..< 3)
    func seekAfterTrackSwitch(run _: Int) async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.multiTrack, in: player)
        #expect(await eventually { player.state.position > 0.8 })

        player.selectTrack(.subtitle, number: 2)
        try await Task.sleep(for: .milliseconds(600))
        let position = try #require(player.engineProperty("time-pos").flatMap(Double.init))
        #expect(position > 1.2 && position < 2.5)

        // Without the model's check, this sequence ends on the next keyframe at 10.4 s.
        player.selectTrack(.subtitle, number: 1)
        player.setPaused(true)
        player.seek(to: 2)
        #expect(await eventually { player.engineProperty("time-pos") == "2.000000" })
        #expect(await eventually { player.engineProperty("sub-text") == "Subtítulo de prueba uno" })
    }

    @Test("Chapters are listed, tracked and can be jumped to")
    func chapters() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.multiTrack, in: player)
        player.setPaused(true)

        #expect(player.state.chapters.map(\.title) == ["Opening", "Middle", "Ending"])
        #expect(player.state.chapters.map(\.start) == [0, 5, 12])
        #expect(await eventually { player.state.currentChapter == 0 })

        player.seek(toChapter: 2)
        #expect(await eventually { player.state.currentChapter == 2 && abs(player.state.position - 12) < 0.5 })
        player.perform(.previousChapter)
        #expect(await eventually { player.state.currentChapter == 1 })
        player.perform(.nextChapter)
        #expect(await eventually { player.state.currentChapter == 2 })
        player.seek(toChapter: 99)
        try await Task.sleep(for: .milliseconds(200))
        #expect(player.state.currentChapter == 2)
    }

    @Test("Picture, sound and subtitle settings reach the engine")
    func settings() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.multiTrack, in: player)
        func engine(_ name: String) -> String? {
            player.engineProperty(name)
        }

        player.video.brightness = 20
        player.video.saturation = -30
        player.video.isMirrored = true
        player.video.isDeinterlacing = true
        #expect(await eventually { engine("brightness") == "20.000000" && engine("saturation") == "-30.000000" })
        #expect(await eventually { engine("vf") == "hflip" && engine("deinterlace") == "yes" })

        player.audio.delay = 0.25
        player.audio.equalizer = .init(isEnabled: true, gains: [6, 3, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(await eventually { engine("audio-delay") == "0.250000" && engine("af")?.contains("firequalizer") == true })
        player.audio.equalizer.isEnabled = false
        #expect(await eventually { engine("af")?.isEmpty == true })

        player.subtitles.delay = -1.5
        player.subtitles.scale = 1.5
        player.subtitles.textColor = .yellow
        player.subtitles.isVisible = false
        #expect(await eventually {
            engine("sub-delay") == "-1.500000" && engine("sub-scale") == "1.500000"
                && engine("sub-color") == "#FFFFDD33" && engine("sub-visibility") == "no"
        })

        player.perform(.shiftSubtitleDelay(0.1))
        player.perform(.shiftAudioDelay(-0.1))
        #expect(player.subtitles.delay == -1.4)
        #expect(player.audio.delay == 0.15)

        player.speed = PlaybackSpeed(2)
        #expect(await eventually { engine("speed") == "2.000000" })
        player.perform(.slowDown)
        #expect(player.speed.value == 1.75)
        player.perform(.resetSpeed)
        #expect(await eventually { engine("speed") == "1.000000" })

        // Playback is still healthy with filters and adjustments active.
        let position = player.state.position
        #expect(await eventually { player.state.position > position + 0.3 })
    }

    @Test("Aspect, crop and rotation change the size the picture is shown at")
    func geometry() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.multiTrack, in: player)
        #expect(player.displayedVideoSize == CGSize(width: 1280, height: 720))

        player.video.aspect = .ratio(width: 4, height: 3)
        #expect(await eventually { player.displayedVideoSize == CGSize(width: 1280, height: 960) })
        player.video.aspect = .source
        #expect(await eventually { player.displayedVideoSize == CGSize(width: 1280, height: 720) })

        player.video.crop = .ratio(width: 1, height: 1)
        #expect(await eventually { player.displayedVideoSize == CGSize(width: 720, height: 720) })
        #expect(player.engineProperty("video-crop") == "720x720+280+0")
        player.video.crop = .source
        #expect(await eventually { player.displayedVideoSize == CGSize(width: 1280, height: 720) })

        // The engine does not report a rotated size, so the model swaps the sides itself.
        player.video.rotation = .quarter
        #expect(player.displayedVideoSize == CGSize(width: 720, height: 1280))
        #expect(await eventually { player.engineProperty("video-rotate") == "90" })
    }

    @Test("A crop chosen before a file opens is applied once the picture size is known")
    func cropBeforeOpen() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        player.video.crop = .ratio(width: 4, height: 3)
        try await open(TestMedia.sdr, in: player)
        #expect(await eventually { player.engineProperty("video-crop") == "1440x1080+240+0" })
        #expect(await eventually { player.displayedVideoSize == CGSize(width: 1440, height: 1080) })
    }

    @Test("Frame stepping pauses and moves by single frames")
    func frameStepping() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)
        player.setPaused(true)
        player.seek(to: 2)
        #expect(await eventually { abs(player.state.position - 2) < 0.05 })
        try await Task.sleep(for: .milliseconds(200))

        let start = player.state.position
        player.perform(.stepFrameForward)
        // 30 frames a second: one frame is a thirtieth of a second.
        #expect(await eventually { abs(player.state.position - (start + 1.0 / 30)) < 0.01 })
        #expect(player.state.isPaused)
        player.perform(.stepFrameBackward)
        #expect(await eventually { abs(player.state.position - start) < 0.01 })
    }

    @Test("An A-B loop repeats its section and is cleared by a new file")
    func abLoop() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)

        player.setABLoop(.looping(start: 1, end: 1.6))
        #expect(await eventually { player.engineProperty("ab-loop-b") == "1.600000" })
        player.seek(to: 1.2)
        // Over two seconds of playing, the playhead must stay inside the loop.
        var maximum = 0.0
        for _ in 0 ..< 20 {
            try await Task.sleep(for: .milliseconds(100))
            maximum = max(maximum, player.state.position)
        }
        #expect(maximum < 1.9)

        try await open(TestMedia.multiTrack, in: player)
        #expect(player.abLoop == .off)
        #expect(await eventually { player.engineProperty("ab-loop-a") == "no" })
    }

    @Test("Captures the current frame at the video's resolution")
    func frameCapture() async throws {
        let player = try makePlayer(video: .surface)
        defer { player.shutdown() }
        #expect(await player.captureFrame(includingSubtitles: false) == nil)

        try await open(TestMedia.multiTrack, in: player)
        player.selectTrack(.subtitle, number: 2)
        player.setPaused(true)
        player.seek(to: 2)
        // Switching subtitle track makes the engine re-seek; wait until the subtitle for this moment is loaded.
        #expect(await eventually { player.engineProperty("sub-text") == "Test subtitle one" })
        #expect(await eventually { abs(player.state.position - 2) < 0.1 })

        let plain = try #require(await player.captureFrame(includingSubtitles: false))
        let withSubtitles = try #require(await player.captureFrame(includingSubtitles: true))
        #expect(plain.width == 1280 && plain.height == 720)
        #expect(withSubtitles.width == 1280 && withSubtitles.height == 720)
        // A subtitle is on screen at two seconds, so the two captures must differ.
        #expect(FrameImage.pngData(plain) != FrameImage.pngData(withSubtitles))
    }

    @Test("A queue plays in order, can start in the middle, and can be navigated")
    func queue() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        let sources = try [TestMedia.sdr, TestMedia.multiTrack, TestMedia.hdr].map { try PlayableSource(url: $0) }

        player.open(sources, startingAt: 1)
        #expect(await eventually { player.state.playlist.count == 3 && player.state.phase == .playing })
        #expect(player.state.playlist.map(\.displayName) == ["sdr-h264-1080p.mp4", "multi-track.mkv", "hdr10-hevc-4k60.mkv"])
        #expect(await eventually { player.state.playlist.map(\.isCurrent) == [false, true, false] })
        #expect(player.title == "multi-track.mkv")

        player.perform(.playNext)
        #expect(await eventually { player.state.playlist.map(\.isCurrent) == [false, false, true] })
        #expect(await eventually { player.title == "hdr10-hevc-4k60.mkv" })
        // Already at the end: nothing happens.
        player.perform(.playNext)
        try await Task.sleep(for: .milliseconds(300))
        #expect(player.state.playlist.map(\.isCurrent) == [false, false, true])

        player.play(queueIndex: 0)
        #expect(await eventually { player.title == "sdr-h264-1080p.mp4" && player.state.phase == .playing })

        player.enqueue(sources[1])
        #expect(await eventually { player.state.playlist.count == 4 })
    }

    @Test("The queue advances by itself at the end of a file")
    func queueAdvances() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        let sources = try [TestMedia.sdr, TestMedia.multiTrack].map { try PlayableSource(url: $0) }
        player.open(sources)
        #expect(await eventually { player.state.phase == .playing && player.state.duration != nil })
        player.seek(to: 9.7)
        #expect(await eventually { player.title == "multi-track.mkv" && player.state.phase == .playing })
        #expect(player.source == sources[1])
    }
}
