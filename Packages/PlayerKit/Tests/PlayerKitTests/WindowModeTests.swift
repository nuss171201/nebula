import AppKit
import Foundation
@testable import PlayerKit
import Testing

@Suite("Window layout (pure)")
struct PlayerWindowLayoutTests {
    private let screen = CGRect(x: 0, y: 40, width: 1800, height: 1100)

    @Test("Picture in picture sits in the bottom right corner, shaped like the video")
    func pictureInPicture() {
        let wide = PlayerWindowLayout.pictureInPictureFrame(video: CGSize(width: 1920, height: 1080), visibleFrame: screen)
        #expect(wide == CGRect(x: 1800 - 20 - 420, y: 60, width: 420, height: 236))
        let tall = PlayerWindowLayout.pictureInPictureFrame(video: CGSize(width: 1080, height: 1920), visibleFrame: screen)
        #expect(tall.size == CGSize(width: 420, height: 747))
        #expect(tall.maxX == 1780 && tall.minY == 60)
        // Nothing known about the video yet: 16:9.
        #expect(PlayerWindowLayout.pictureInPictureFrame(video: nil, visibleFrame: screen).size == CGSize(width: 420, height: 236))
    }

    @Test("On a screen too small for it, picture in picture shrinks to fit inside the margins")
    func smallScreen() {
        let small = CGRect(x: 0, y: 0, width: 400, height: 300)
        let frame = PlayerWindowLayout.pictureInPictureFrame(video: CGSize(width: 1080, height: 1920), visibleFrame: small)
        #expect(frame.height <= 260 && frame.width <= 360)
        #expect(abs(frame.width / frame.height - 1080.0 / 1920.0) < 0.02)
        #expect(small.contains(frame))
    }

    @Test("A new video reshapes picture in picture without moving it away from its edge")
    func reshaping() {
        let atBottom = CGRect(x: 1360, y: 60, width: 420, height: 236)
        let taller = PlayerWindowLayout.reshapedPictureInPictureFrame(current: atBottom, video: CGSize(width: 4, height: 3), visibleFrame: screen)
        #expect(taller == CGRect(x: 1360, y: 60, width: 420, height: 315))
        // Parked at the top: the top edge stays where it is.
        let atTop = CGRect(x: 100, y: 1140 - 20 - 236, width: 420, height: 236)
        let fromTop = PlayerWindowLayout.reshapedPictureInPictureFrame(current: atTop, video: CGSize(width: 4, height: 3), visibleFrame: screen)
        #expect(fromTop.maxY == atTop.maxY && fromTop.height == 315)
    }

    @Test("The mini player keeps the top left corner of the window it replaces")
    func mini() {
        let frame = PlayerWindowLayout.miniFrame(replacing: CGRect(x: 200, y: 300, width: 1280, height: 720))
        #expect(frame.origin.x == 200 && frame.maxY == 1020)
        #expect(frame.size == PlayerWindowLayout.miniSize)
    }
}

@MainActor
@Suite("Window modes", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct PlayerWindowModeTests {
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

    /// The window is never shown; the tests drive it directly.
    private func makeController() throws -> PlayerWindowController {
        try PlayerWindowController(model: PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            playsAudio: false
        )))
    }

    private func contentSize(_ controller: PlayerWindowController) -> CGSize {
        controller.window.contentRect(forFrameRect: controller.window.frame).size
    }

    @Test("Picture in picture is a small floating window on every Space; leaving it restores the normal window")
    func pictureInPicture() async throws {
        let controller = try makeController()
        defer { controller.close() }
        try controller.model.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { controller.window.contentAspectRatio == NSSize(width: 1920, height: 1080) })
        let normalFrame = controller.window.frame
        controller.chrome.isQueueVisible = true

        #expect(controller.perform(.togglePictureInPicture))
        #expect(controller.mode == .pictureInPicture)
        #expect(controller.window.level == .floating)
        #expect(controller.window.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
        #expect(!controller.window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(controller.window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(!controller.chrome.isSidePanelVisible)
        let small = contentSize(controller)
        #expect(small.width == PlayerWindowLayout.pictureInPictureWidth)
        #expect(abs(small.width / small.height - 16.0 / 9.0) < 0.01)
        if let visible = (controller.window.screen ?? NSScreen.main)?.visibleFrame {
            #expect(abs(controller.window.frame.maxX - (visible.maxX - PlayerWindowLayout.margin)) < 1)
        }
        // Playback carries on.
        let position = controller.model.state.position
        #expect(await eventually { controller.model.state.position > position + 0.3 })

        // A video of another shape reshapes the small window instead of resizing it to the video.
        try controller.model.open(PlayableSource(url: TestMedia.hdr))
        #expect(await eventually { controller.model.state.videoSize == CGSize(width: 3840, height: 2160) })
        #expect(contentSize(controller).width == PlayerWindowLayout.pictureInPictureWidth)

        // Escape returns to the normal window.
        #expect(controller.perform(.exitFullScreen))
        #expect(controller.mode == .standard)
        #expect(controller.window.level == .normal)
        #expect(controller.window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!controller.window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(controller.window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(contentSize(controller).width >= PlayerWindowLayout.standardMinimum.width)
        #expect(abs(controller.window.frame.midX - normalFrame.midX) < 2)
    }

    @Test("Always on top floats the normal window, and survives a trip through picture in picture")
    func alwaysOnTop() throws {
        let controller = try makeController()
        defer { controller.close() }
        #expect(controller.window.level == .normal)
        #expect(controller.perform(.toggleAlwaysOnTop))
        #expect(controller.chrome.isAlwaysOnTop && controller.window.level == .floating)
        #expect(controller.model.notice?.text == "Always on Top")
        controller.setMode(.pictureInPicture)
        controller.setMode(.standard)
        #expect(controller.window.level == .floating)
        #expect(controller.perform(.toggleAlwaysOnTop))
        #expect(controller.window.level == .normal)
    }

    @Test("The mini player is a fixed-height window that stops decoding the picture")
    func miniPlayer() async throws {
        let controller = try makeController()
        defer { controller.close() }
        try controller.model.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { controller.model.state.phase == .playing && controller.model.state.videoSize != nil })

        #expect(controller.perform(.toggleMiniPlayer))
        #expect(controller.mode == .mini)
        #expect(contentSize(controller) == PlayerWindowLayout.miniSize)
        #expect(controller.window.contentMinSize.height == controller.window.contentMaxSize.height)
        #expect(await eventually { controller.model.engineProperty("vid") == "no" })
        let position = controller.model.state.position
        #expect(await eventually { controller.model.state.position > position + 0.3 })

        // Settings need the normal window: asking for them goes back to it and brings the picture back.
        #expect(controller.perform(.toggleSettings(.audio)))
        #expect(controller.mode == .standard && controller.chrome.isSettingsPanelVisible)
        #expect(await eventually { controller.model.engineProperty("vid") == "1" })
        #expect(await eventually { controller.model.state.videoSize != nil })
        #expect(abs(contentSize(controller).width / contentSize(controller).height - 16.0 / 9.0) < 0.01)
    }

    @Test("Sound without a picture gets the mini player by itself; a video after it gets the normal window back")
    func audioOnly() async throws {
        let controller = try makeController()
        defer { controller.close() }
        try controller.model.open(PlayableSource(url: TestMedia.audioOnly))
        #expect(await eventually { controller.model.state.isAudioOnly })
        #expect(await eventually { controller.mode == .mini })
        #expect(await eventually { controller.window.title == "Test Tone" })

        try controller.model.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { controller.mode == .standard })
        #expect(await eventually { controller.model.state.videoSize != nil })

        // A mini player the user asked for stays, whatever is played in it.
        controller.setMode(.mini)
        try controller.model.open(PlayableSource(url: TestMedia.multiTrack))
        #expect(await eventually { controller.model.state.phase == .playing && controller.model.title == "multi-track.mkv" })
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.mode == .mini)
    }
}
