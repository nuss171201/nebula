import AppKit
import Foundation
@testable import PlayerKit
import Testing

@MainActor
@Suite("Player controls visibility")
struct PlayerChromeModelTests {
    /// A chrome model whose hide timer fires as soon as it is awaited.
    private func makeChrome() -> PlayerChromeModel {
        PlayerChromeModel(hideDelay: .seconds(2.5), sleep: { _ in })
    }

    @Test("Controls hide after the pointer rests during playback, and come back on movement")
    func hidesWhilePlaying() async {
        let chrome = makeChrome()
        #expect(chrome.isVisible)
        chrome.playbackChanged(isPlaying: true)
        await chrome.waitForPendingHide()
        #expect(!chrome.isVisible)

        chrome.userDidInteract()
        #expect(chrome.isVisible)
        await chrome.waitForPendingHide()
        #expect(!chrome.isVisible)
    }

    @Test("Controls stay up while paused, loading or ended")
    func staysWhileNotPlaying() async {
        let chrome = makeChrome()
        chrome.playbackChanged(isPlaying: false)
        chrome.userDidInteract()
        await chrome.waitForPendingHide()
        #expect(chrome.isVisible)

        // Pausing while hidden brings them back.
        chrome.playbackChanged(isPlaying: true)
        await chrome.waitForPendingHide()
        #expect(!chrome.isVisible)
        chrome.playbackChanged(isPlaying: false)
        #expect(chrome.isVisible)
    }

    @Test("Controls stay up while the pointer is on them")
    func staysWhileHovered() async {
        let chrome = makeChrome()
        chrome.playbackChanged(isPlaying: true)
        chrome.userDidInteract()
        chrome.pointerIsOnControls(true)
        await chrome.waitForPendingHide()
        #expect(chrome.isVisible)

        chrome.pointerIsOnControls(false)
        await chrome.waitForPendingHide()
        #expect(!chrome.isVisible)
    }

    @Test("Movement during the delay restarts it instead of hiding early")
    func movementRestartsTimer() async {
        let chrome = PlayerChromeModel(hideDelay: .milliseconds(150))
        chrome.playbackChanged(isPlaying: true)
        try? await Task.sleep(for: .milliseconds(100))
        chrome.userDidInteract()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(chrome.isVisible)
        await chrome.waitForPendingHide()
        #expect(!chrome.isVisible)
    }
}

@Suite("Key translation")
struct KeyChordTests {
    @Test("Key codes and characters become chords", arguments: [
        (UInt16(49), " ", KeyChord(.space)),
        (123, "", KeyChord(.leftArrow)),
        (124, "", KeyChord(.rightArrow)),
        (126, "", KeyChord(.upArrow)),
        (125, "", KeyChord(.downArrow)),
        (53, "", KeyChord(.escape)),
        (36, "\r", KeyChord(.returnKey)),
        (76, "\u{3}", KeyChord(.returnKey)),
        (3, "f", KeyChord(.character("f"))),
        (3, "F", KeyChord(.character("f"))),
    ])
    func translation(keyCode: UInt16, characters: String, expected: KeyChord) {
        #expect(KeyChord(keyCode: keyCode, characters: characters, modifierFlags: []) == expected)
    }

    @Test("Modifier keys are carried, and unnamed keys are ignored")
    func modifiersAndUnknownKeys() {
        let chord = KeyChord(keyCode: 124, characters: "", modifierFlags: [.shift, .command])
        #expect(chord == KeyChord(.rightArrow, [.shift, .command]))
        #expect(KeyChord(keyCode: 122, characters: "\u{F704}", modifierFlags: []) == nil)
        #expect(KeyChord(keyCode: 0, characters: nil, modifierFlags: []) == nil)
    }
}

@MainActor
@Suite("Player window", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct PlayerWindowControllerTests {
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

    private func makeController() throws -> PlayerWindowController {
        let model = try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            playsAudio: false
        ))
        // The window is never shown; the tests drive it directly.
        return PlayerWindowController(model: model)
    }

    @Test("The window takes the media's title and proportions")
    func followsMedia() async throws {
        let controller = try makeController()
        defer { controller.close() }
        try controller.model.open(PlayableSource(url: TestMedia.sdr))

        #expect(await eventually { controller.window.title == "sdr-h264-1080p.mp4" })
        #expect(await eventually { controller.window.contentAspectRatio == NSSize(width: 1920, height: 1080) })
        let content = controller.window.contentLayoutRect.size
        #expect(content.width >= 640)
        let frame = controller.window.contentRect(forFrameRect: controller.window.frame).size
        #expect(abs(frame.width / frame.height - 16.0 / 9.0) < 0.01)
    }

    @Test("Commands reach the player or the window as appropriate")
    func commands() async throws {
        let controller = try makeController()
        defer { controller.close() }
        try controller.model.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { controller.model.state.phase == .playing })

        #expect(controller.perform(.togglePause))
        #expect(await eventually { controller.model.state.isPaused })
        #expect(controller.perform(.changeVolumeBy(-40)))
        #expect(controller.model.state.volume == 60)
        #expect(controller.perform(.toggleMute))
        #expect(controller.model.state.isMuted)

        // The settings shortcuts act on the window's panel; Escape closes it before anything else.
        #expect(controller.perform(.toggleSettings(.audio)))
        #expect(controller.chrome.isSettingsPanelVisible && controller.chrome.settingsTab == .audio)
        #expect(controller.perform(.exitFullScreen))
        #expect(!controller.chrome.isSettingsPanelVisible)

        // Leaving full screen when not in it is not handled, so Escape can fall through.
        #expect(!controller.isFullScreen)
        #expect(!controller.perform(.exitFullScreen))
    }

    @Test("Closing the window shuts the player down")
    func closing() async throws {
        let controller = try makeController()
        try controller.model.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { controller.model.state.phase == .playing })

        var closed = 0
        var shutDown = 0
        controller.onClose = { closed += 1 }
        controller.model.onShutdown = { shutDown += 1 }
        controller.close()
        #expect(closed == 1)
        #expect(await eventually { shutDown == 1 })
    }
}

@Suite("Canvas geometry")
struct CanvasGeometryTests {
    private let canvas = CGSize(width: 3024, height: 1964)

    @Test("The canvas matches the screen's pixels, with even sizes and a cap on very large screens")
    func canvasSize() {
        #expect(CanvasGeometry.canvasSize(forScreenPixels: CGSize(width: 3024, height: 1964)) == CGSize(width: 3024, height: 1964))
        #expect(CanvasGeometry.canvasSize(forScreenPixels: CGSize(width: 2561, height: 1441)) == CGSize(width: 2560, height: 1440))
        // A 6K display: scaled to a 3840-pixel long edge, same proportions.
        let large = CanvasGeometry.canvasSize(forScreenPixels: CGSize(width: 6016, height: 3384))
        #expect(large == CGSize(width: 3840, height: 2160))
        #expect(CanvasGeometry.canvasSize(forScreenPixels: .zero) == CanvasGeometry.fallbackSize)
    }

    @Test("The engine's video rectangle is the video aspect-fitted and centred in the canvas")
    func videoRect() {
        let wide = CanvasGeometry.videoRect(canvas: canvas, video: CGSize(width: 1920, height: 1080))
        #expect(wide == CGRect(x: 0, y: 131.5, width: 3024, height: 1701))

        let tall = CanvasGeometry.videoRect(canvas: canvas, video: CGSize(width: 1080, height: 1920))
        #expect(abs(tall.width - 1104.75) < 0.001)
        #expect(tall.height == 1964)
        #expect(abs(tall.midX - 1512) < 0.001)

        #expect(CanvasGeometry.videoRect(canvas: canvas, video: nil) == CGRect(origin: .zero, size: canvas))
    }

    @Test("A window with the video's proportions shows exactly the video, at any size")
    func windowedScale() {
        let video = CGSize(width: 1920, height: 1080)
        for width in [480.0, 960.0, 1512.0] {
            let view = CGSize(width: width, height: width * 9 / 16)
            let scale = CanvasGeometry.scale(canvas: canvas, video: video, view: view)
            #expect(abs(scale * 3024 - width) < 0.001)
            #expect(abs(scale * 1701 - view.height) < 0.001)
        }
    }

    @Test("Full screen on the canvas's own screen maps canvas pixels to screen pixels one to one")
    func fullScreenScale() {
        // The screen is 1512×982 points at 2×, so half a point per canvas pixel is pixel-exact.
        let screenPoints = CGSize(width: 1512, height: 982)
        #expect(CanvasGeometry.scale(canvas: canvas, video: CGSize(width: 1920, height: 1080), view: screenPoints) == 0.5)
        #expect(CanvasGeometry.scale(canvas: canvas, video: nil, view: screenPoints) == 0.5)
    }

    @Test("A view with other proportions letterboxes the video rather than cropping it")
    func mismatchedView() {
        let video = CGSize(width: 1920, height: 1080)
        // A square view: limited by width.
        let scale = CanvasGeometry.scale(canvas: canvas, video: video, view: CGSize(width: 600, height: 600))
        #expect(abs(scale * 3024 - 600) < 0.001)
        #expect(scale * 1701 < 600)
        #expect(CanvasGeometry.scale(canvas: canvas, video: video, view: .zero) == 1)
    }
}

@Suite("Track and value presentation")
struct TrackPresentationTests {
    private let english = Locale(identifier: "en")

    @Test("Tracks are named by language, with the title where it adds something")
    func names() {
        #expect(MediaTrack(kind: .audio, number: 1, title: "Français", language: "fra").displayName(locale: english) == "French")
        #expect(MediaTrack(kind: .audio, number: 2, title: "Surround", language: "eng").displayName(locale: english) == "English — Surround")
        #expect(MediaTrack(kind: .audio, number: 3, title: "English").displayName(locale: english) == "English")
        #expect(MediaTrack(kind: .audio, number: 4, language: "jpn").displayName(locale: english) == "Japanese")
        #expect(MediaTrack(kind: .subtitle, number: 5).displayName(locale: english) == "Track 5")
    }

    @Test("The small print shows codec, layout or size, and flags")
    func details() {
        #expect(MediaTrack(kind: .audio, number: 1, codec: "eac3", isDefault: true, channelCount: 6).detail == "E-AC-3 · 5.1 · Default")
        #expect(MediaTrack(kind: .audio, number: 2, codec: "dts", channelCount: 8).detail == "DTS · 7.1")
        #expect(MediaTrack(kind: .audio, number: 3, codec: "aac", channelCount: 2).detail == "AAC · Stereo")
        #expect(MediaTrack(kind: .audio, number: 4, codec: "weird", channelCount: 3).detail == "WEIRD · 3 channels")
        #expect(MediaTrack(kind: .video, number: 1, codec: "hevc", width: 3840, height: 2160, framesPerSecond: 59.94).detail == "HEVC · 3840×2160 · 59.94 fps")
        #expect(MediaTrack(kind: .subtitle, number: 1, codec: "subrip", isForced: true, isExternal: true).detail == "SRT · Forced · External")
        #expect(MediaTrack(kind: .subtitle, number: 2).detail.isEmpty)
    }

    @Test("Delays are shown with a sign and no trailing zeros", arguments: [
        (0.0, "0 s"), (0.25, "+0.25 s"), (-1.5, "−1.5 s"), (2.0, "+2 s"), (0.0004, "0 s"),
    ])
    func delays(seconds: Double, expected: String) {
        #expect(formattedDelay(seconds) == expected)
    }
}

@MainActor
@Suite("Settings panel")
struct SettingsPanelTests {
    @Test("A tab's shortcut opens the panel on it, switches to it, or closes it")
    func toggling() {
        let chrome = PlayerChromeModel(sleep: { _ in })
        #expect(!chrome.isSettingsPanelVisible)
        chrome.toggleSettingsPanel(.audio)
        #expect(chrome.isSettingsPanelVisible && chrome.settingsTab == .audio)
        chrome.toggleSettingsPanel(.subtitles)
        #expect(chrome.isSettingsPanelVisible && chrome.settingsTab == .subtitles)
        chrome.toggleSettingsPanel(.subtitles)
        #expect(!chrome.isSettingsPanelVisible)
    }

    @Test("Controls do not hide while the panel is open")
    func keepsControlsVisible() async {
        let chrome = PlayerChromeModel(sleep: { _ in })
        chrome.playbackChanged(isPlaying: true)
        await chrome.waitForPendingHide()
        #expect(!chrome.isVisible)

        chrome.isSettingsPanelVisible = true
        #expect(chrome.isVisible)
        chrome.userDidInteract()
        await chrome.waitForPendingHide()
        #expect(chrome.isVisible)

        chrome.isSettingsPanelVisible = false
        await chrome.waitForPendingHide()
        #expect(!chrome.isVisible)
    }

    @Test("Subtitle colours convert to and from display colours")
    func colours() {
        let yellow = SubtitleSettings.Color.yellow
        #expect(SubtitleSettings.Color(yellow.color) == yellow)
        #expect(SubtitleSettings.Color(.white) == .white)
    }
}
