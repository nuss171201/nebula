import AppKit
import Foundation
@testable import PlayerKit
import Testing

@Suite("HDR and audio output settings (pure)")
struct OutputSettingsTests {
    @Test("The video's brightness curve says whether it is HDR, and which kind")
    func dynamicRange() {
        var state = PlaybackState()
        #expect(state.dynamicRange == .standard && !state.dynamicRange.isHDR)
        state.apply(.property(.transferFunction("pq")))
        #expect(state.dynamicRange == .hdr10 && state.dynamicRange.isHDR)
        state.apply(.property(.transferFunction("hlg")))
        #expect(state.dynamicRange == .hlg)
        state.apply(.property(.transferFunction("bt.1886")))
        #expect(state.dynamicRange == .standard)
        // It belongs to the file: a new file starts as standard until its first frame says otherwise.
        state.apply(.property(.transferFunction("pq")))
        state.apply(.startedLoading)
        #expect(state.dynamicRange == .standard)
    }

    @Test("Tone mapping and the audio output options translate to engine values")
    func writes() {
        var video = VideoSettings()
        #expect(video.engineWrites(sourceSize: nil).contains(EngineWrite("tone-mapping", .string("auto"))))
        video.toneMapping = .st2094
        #expect(video.engineWrites(sourceSize: nil).contains(EngineWrite("tone-mapping", .string("st2094-40"))))

        var audio = AudioSettings()
        #expect(audio.engineWrites().contains(EngineWrite("audio-channels", .string("auto-safe"))))
        #expect(audio.engineWrites().contains(EngineWrite("audio-pitch-correction", .flag(true))))
        audio.isDownmixingToStereo = true
        audio.keepsPitch = false
        #expect(audio.engineWrites().contains(EngineWrite("audio-channels", .string("stereo"))))
        #expect(audio.engineWrites().contains(EngineWrite("audio-pitch-correction", .flag(false))))
    }

    @Test("The status line says what the video is and what is being done with it", arguments: [
        (VideoDynamicRange.standard, Int?.none, false, true, "This video is standard dynamic range."),
        (.hdr10, nil, true, true, "HDR10, shown in HDR."),
        (.hdr10, nil, false, true, "HDR10, converted to standard range."),
        (.hdr10, nil, false, false, "HDR10, converted to standard range, because this display cannot show HDR."),
        (.hlg, nil, true, true, "HLG, shown in HDR."),
        (.hdr10, 8, true, true, "Dolby Vision, shown in HDR as HDR10 (a true Dolby Vision signal cannot be produced)."),
        (.hdr10, 5, false, false, "Dolby Vision, converted to standard range, because this display cannot show HDR."),
    ])
    func status(range: VideoDynamicRange, profile: Int?, isShowingHDR: Bool, displaySupportsHDR: Bool, expected: String) {
        let text = HDRStatus.text(range: range, dolbyVisionProfile: profile, isShowingHDR: isShowingHDR, displaySupportsHDR: displaySupportsHDR)
        #expect(text == expected)
    }
}

@MainActor
@Suite("HDR output through the engine", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct HDROutputEngineTests {
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

    private func colorSpace(of surface: PlayerSurfaceView) -> String {
        (surface.canvasLayer.colorspace?.name as String?) ?? "none"
    }

    @Test("HDR video is sent to an HDR display as HDR, and converted otherwise; standard video is never touched")
    func switchesOutput() async throws {
        let player = try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .surface,
            playsAudio: false
        ))
        defer { player.shutdown() }
        let surface = try #require(player.surface)
        // Never shown: the engine renders into the layer whether or not the window is on screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = surface

        // A display without HDR: the video is recognised as HDR and converted.
        player.displaySupportsHDR = false
        try player.open(PlayableSource(url: TestMedia.hdr))
        #expect(await eventually { player.state.dynamicRange == .hdr10 && player.state.hasShownFirstFrame })
        #expect(!player.isShowingHDR)
        #expect(player.engineProperty("target-colorspace-hint") == "no")
        #expect(await eventually { player.engineProperty("video-target-params/gamma") != "pq" })

        // The window moves to a display with HDR.
        player.displaySupportsHDR = true
        #expect(player.isShowingHDR)
        #expect(surface.canvasLayer.wantsExtendedDynamicRangeContent)
        #expect(await eventually { player.engineProperty("video-target-params/gamma") == "pq" })
        #expect(await eventually { colorSpace(of: surface) == (CGColorSpace.itur_2100_PQ as String) })
        // The canvas keeps its size through the change of colour space.
        #expect(surface.canvasLayer.drawableSize == surface.canvasSize)
        let position = player.state.position
        #expect(await eventually { player.state.position > position + 0.5 })

        // The user asks for standard range.
        player.video.hdrOutput = .off
        #expect(!player.isShowingHDR)
        #expect(await eventually { player.engineProperty("video-target-params/gamma") != "pq" })
        #expect(await eventually { colorSpace(of: surface) == (CGColorSpace.sRGB as String) })
        #expect(await eventually { !surface.canvasLayer.wantsExtendedDynamicRangeContent })

        player.video.hdrOutput = .automatic
        #expect(player.isShowingHDR)
        #expect(await eventually { colorSpace(of: surface) == (CGColorSpace.itur_2100_PQ as String) })

        // A standard video follows: HDR output goes off again, and its colours are left as they always were.
        try player.open(PlayableSource(url: TestMedia.sdr))
        #expect(!player.isShowingHDR)
        #expect(await eventually { player.state.hasShownFirstFrame && player.state.position > 0.3 })
        #expect(player.state.dynamicRange == .standard && !player.isShowingHDR)
        #expect(player.engineProperty("target-colorspace-hint") == "no")
        #expect(await eventually { colorSpace(of: surface) == (CGColorSpace.sRGB as String) })
    }

    @Test("Downmixing and pitch correction reach the engine")
    func audioOutput() async throws {
        let player = try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .none,
            playsAudio: false
        ))
        defer { player.shutdown() }
        try player.open(PlayableSource(url: TestMedia.multiTrack))
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
        player.audio.isDownmixingToStereo = true
        player.audio.keepsPitch = false
        #expect(await eventually { player.engineProperty("audio-channels") == "stereo" })
        #expect(await eventually { player.engineProperty("audio-pitch-correction") == "no" })
        let position = player.state.position
        #expect(await eventually { player.state.position > position + 0.3 })
    }
}

@Suite("Defaults carried from one video to the next")
struct PlayerDefaultsTests {
    @Test("What carries over is taken from the panel's settings and gives them back; what belongs to one file does not")
    func roundTrip() throws {
        var video = VideoSettings()
        video.hdrOutput = .off
        video.toneMapping = .hable
        video.usesHardwareDecoding = false
        video.brightness = 20
        video.rotation = .quarter
        var audio = AudioSettings()
        audio.equalizer = AudioSettings.Equalizer(isEnabled: true, gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0])
        audio.isDownmixingToStereo = true
        audio.keepsPitch = false
        audio.delay = 0.3
        var subtitles = SubtitleSettings()
        subtitles.scale = 1.4
        subtitles.position = 92
        subtitles.fontName = "Helvetica Neue"
        subtitles.textColor = .yellow
        subtitles.borderSize = 3
        subtitles.overridesEmbeddedStyle = true
        subtitles.delay = -1.5
        subtitles.isVisible = false

        let defaults = PlayerDefaults(video: video, audio: audio, subtitles: subtitles)
        let stored = try JSONDecoder().decode(PlayerDefaults.self, from: JSONEncoder().encode(defaults))
        #expect(stored == defaults)
        let restored = stored.settings()
        #expect(restored.video.hdrOutput == .off && restored.video.toneMapping == .hable && !restored.video.usesHardwareDecoding)
        #expect(restored.audio.equalizer == audio.equalizer && restored.audio.isDownmixingToStereo && !restored.audio.keepsPitch)
        #expect(restored.subtitles.scale == 1.4 && restored.subtitles.position == 92 && restored.subtitles.fontName == "Helvetica Neue")
        #expect(restored.subtitles.textColor == .yellow && restored.subtitles.borderSize == 3 && restored.subtitles.overridesEmbeddedStyle)
        // Per-file things start afresh.
        #expect(restored.video.brightness == 0 && restored.video.rotation == .none)
        #expect(restored.audio.delay == 0 && restored.subtitles.delay == 0 && restored.subtitles.isVisible)
    }

    @Test("Stored defaults from another version are read as far as they go")
    func lenientDecoding() throws {
        let partial = try JSONDecoder().decode(PlayerDefaults.self, from: Data(#"{"subtitleScale": 2, "toneMapping": "no-such-curve", "extra": true}"#.utf8))
        #expect(partial.subtitleScale == 2 && partial.keepsPitch && partial.subtitleTextColor == "#FFFFFF")
        // A curve this version does not know falls back to automatic.
        #expect(partial.settings().video.toneMapping == .automatic)
        #expect(try JSONDecoder().decode(PlayerDefaults.self, from: Data("{}".utf8)) == PlayerDefaults())
        #expect(SubtitleSettings.Color(hex: "#FFDD33") == .yellow && SubtitleSettings.Color(hex: "000000") == .black)
        #expect(SubtitleSettings.Color(hex: "#12") == nil && SubtitleSettings.Color(hex: "#GGGGGG") == nil)
    }
}

@MainActor
@Suite("Defaults through the engine", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct PlayerDefaultsEngineTests {
    @Test("A new player starts with the stored defaults, and reports them back when the panel changes")
    func appliesAndReports() async throws {
        var defaults = PlayerDefaults()
        defaults.subtitleScale = 1.5
        defaults.downmixesToStereo = true
        defaults.toneMapping = VideoSettings.ToneMapping.mobius.rawValue
        let player = try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .none,
            playsAudio: false,
            defaults: defaults
        ))
        defer { player.shutdown() }
        #expect(player.subtitles.scale == 1.5 && player.audio.isDownmixingToStereo && player.video.toneMapping == .mobius)
        #expect(player.currentDefaults == defaults)
        for _ in 0 ..< 200 where player.engineProperty("sub-scale").flatMap(Double.init) != 1.5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.engineProperty("sub-scale").flatMap(Double.init) == 1.5)
        #expect(player.engineProperty("audio-channels") == "stereo")
        #expect(player.engineProperty("tone-mapping") == "mobius")

        // A change in the panel that carries over shows in the defaults; one that does not, does not.
        player.subtitles.borderSize = 4
        player.subtitles.delay = 2
        #expect(player.currentDefaults.subtitleBorderSize == 4)
        var expected = defaults
        expected.subtitleBorderSize = 4
        #expect(player.currentDefaults == expected)
    }
}
