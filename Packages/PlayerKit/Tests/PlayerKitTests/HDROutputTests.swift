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
