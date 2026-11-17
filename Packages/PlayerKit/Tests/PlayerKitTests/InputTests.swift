import Foundation
@testable import PlayerKit
import Testing

@Suite("Scroll and pinch gestures (pure)")
struct GestureTests {
    @Test("A vertical trackpad scroll changes the volume, a point for every few points of travel")
    func volume() {
        var scroll = ScrollInterpreter()
        scroll.begin()
        #expect(scroll.scroll(right: 0.2, up: 3, isPrecise: true) == nil)
        // 3 + 6 = 9 points of travel: two volume points, one point of travel carried over.
        #expect(scroll.scroll(right: 0, up: 6, isPrecise: true) == .changeVolumeBy(2))
        #expect(scroll.scroll(right: 0, up: 3, isPrecise: true) == .changeVolumeBy(1))
        #expect(scroll.scroll(right: 0, up: -9, isPrecise: true) == .changeVolumeBy(-2))
    }

    @Test("A gesture that starts sideways seeks, and stays a seek even if it drifts")
    func seeking() {
        var scroll = ScrollInterpreter()
        scroll.begin()
        #expect(scroll.scroll(right: 12, up: 2, isPrecise: true) == .seekBy(2))
        // Mostly vertical now, but this gesture is a seek: only its sideways part counts.
        #expect(scroll.scroll(right: 6, up: 40, isPrecise: true) == .seekBy(1))
        #expect(scroll.scroll(right: -30, up: 0, isPrecise: true) == .seekBy(-5))

        // The next gesture chooses afresh.
        scroll.begin()
        #expect(scroll.scroll(right: 1, up: 8, isPrecise: true) == .changeVolumeBy(2))
    }

    @Test("Tiny movements do not start a gesture, and a mouse wheel acts click by click")
    func smallAndWheel() {
        var scroll = ScrollInterpreter()
        scroll.begin()
        #expect(scroll.scroll(right: 0.2, up: 0.3, isPrecise: true) == nil)
        #expect(scroll.scroll(right: 0, up: 1, isPrecise: false) == .changeVolumeBy(2))
        #expect(scroll.scroll(right: 0, up: -3, isPrecise: false) == .changeVolumeBy(-2))
        #expect(scroll.scroll(right: 1, up: 0, isPrecise: false) == .seekBy(5))
        #expect(scroll.scroll(right: -1, up: 0, isPrecise: false) == .seekBy(-5))
        #expect(scroll.scroll(right: 0, up: 0, isPrecise: false) == nil)
    }

    @Test("A clear pinch enters or leaves full screen, once")
    func pinch() {
        var pinch = PinchInterpreter()
        pinch.begin()
        #expect(pinch.magnify(by: 0.1) == nil)
        #expect(pinch.magnify(by: 0.2) == .enterFullScreen)
        #expect(pinch.magnify(by: 0.5) == nil)
        pinch.begin()
        #expect(pinch.magnify(by: -0.3) == .exitFullScreen)
        // A hesitant pinch that returns to where it started does nothing.
        pinch.begin()
        #expect(pinch.magnify(by: 0.2) == nil)
        #expect(pinch.magnify(by: -0.2) == nil)
    }
}

@Suite("Key bindings as text")
struct KeyBindingCodingTests {
    @Test("Chords are written with modifiers in a fixed order and read back from several spellings", arguments: [
        (KeyChord(.space), "space", ["space", "SPACE"]),
        (KeyChord(.leftArrow, [.shift]), "shift+left", ["shift+left", "Shift+Left"]),
        (KeyChord(.character("s"), [.command, .option]), "opt+cmd+s", ["cmd+alt+s", "option+command+s", "opt+cmd+s"]),
        (KeyChord(.character("]")), "]", ["]"]),
        (KeyChord(.character("+"), [.control]), "ctrl+plus", ["ctrl+plus", "control+plus"]),
        (KeyChord(.escape), "esc", ["esc"]),
    ])
    func chords(chord: KeyChord, text: String, spellings: [String]) {
        #expect(chord.text == text)
        for spelling in spellings {
            #expect(KeyChord(text: spelling) == chord)
        }
    }

    @Test("Text that names no key is refused", arguments: ["", "cmd+", "cmd+shift", "f13x", "a+b", "hyper+k"])
    func badChords(text: String) {
        #expect(KeyChord(text: text) == nil)
    }

    @Test("Every standard binding survives being written out and read back")
    func roundTrip() {
        for (chord, command) in KeyBindings.standard.commands {
            #expect(KeyChord(text: chord.text) == chord)
            let identifier = command.identifier
            #expect(identifier != nil, "\(command) has no identifier")
            #expect(identifier.flatMap(PlayerCommand.init(identifier:)) == command)
        }
    }

    @Test("Commands carry their amounts; commands that make no sense on a key have no name")
    func commands() {
        #expect(PlayerCommand.seekBy(-5).identifier == "seek:-5")
        #expect(PlayerCommand.shiftSubtitleDelay(0.1).identifier == "subtitle-delay:0.1")
        #expect(PlayerCommand(identifier: "volume:2.5") == .changeVolumeBy(2.5))
        #expect(PlayerCommand(identifier: "picture-in-picture") == .togglePictureInPicture)
        #expect(PlayerCommand.seekTo(10).identifier == nil)
        #expect(PlayerCommand.setPaused(true).identifier == nil)
        #expect(PlayerCommand(identifier: "seek:fast") == nil)
        #expect(PlayerCommand(identifier: "seek:nan") == nil)
        #expect(PlayerCommand(identifier: "launch-missiles") == nil)
    }

    @Test("The user's changes go on top of the standard bindings, and can be worked out again")
    func overrides() {
        let custom = KeyBindings.standard.applying(overrides: [
            "j": "seek:-10",
            "space": "none",
            "cmd+left": "queue-previous",
            "not a key": "pause",
            "q": "not a command",
        ])
        #expect(custom.command(for: KeyChord(.character("j"))) == .seekBy(-10))
        #expect(custom.command(for: KeyChord(.space)) == nil)
        #expect(custom.command(for: KeyChord(.leftArrow, .command)) == .playPrevious)
        #expect(custom.command(for: KeyChord(.character("q"))) == nil)
        // Untouched bindings are still there.
        #expect(custom.command(for: KeyChord(.character("k"))) == .togglePause)

        let difference = custom.overrides(comparedTo: .standard)
        #expect(difference == ["j": "seek:-10", "space": "none", "cmd+left": "queue-previous"])
        #expect(KeyBindings.standard.applying(overrides: difference) == custom)
        #expect(KeyBindings.standard.overrides(comparedTo: .standard).isEmpty)
    }
}

/// Records what the system's Now Playing display would have been told.
@MainActor
private final class FakeNowPlayingCenter: NowPlayingCenter {
    var updates: [NowPlayingSnapshot?] = []
    var onCommand: (@MainActor (PlayerCommand) -> Void)?

    func update(_ snapshot: NowPlayingSnapshot?) {
        updates.append(snapshot)
    }
}

@Suite("Now Playing (pure)")
struct NowPlayingSnapshotTests {
    private let playing = NowPlayingSnapshot(title: "Film", duration: 100, position: 10, speed: 1, isPlaying: true, hasNext: false, hasPrevious: false)

    @Test("Ordinary playback needs no updates: the system keeps its own clock")
    func steadyPlayback() {
        var later = playing
        later.position = 15.2
        #expect(!later.needsUpdate(after: playing, secondsSince: 5))
        // At double speed the system expects twice the progress.
        var fast = playing
        fast.speed = 2
        var fastLater = fast
        fastLater.position = 20
        #expect(!fastLater.needsUpdate(after: fast, secondsSince: 5))
    }

    @Test("A seek, a pause, a new title or a change of speed is told at once")
    func changes() {
        var seeked = playing
        seeked.position = 60
        #expect(seeked.needsUpdate(after: playing, secondsSince: 1))
        var paused = playing
        paused.isPlaying = false
        paused.position = 11
        #expect(paused.needsUpdate(after: playing, secondsSince: 1))
        // While paused the position is not expected to move.
        var stillPaused = paused
        #expect(!stillPaused.needsUpdate(after: paused, secondsSince: 30))
        stillPaused.position = 40
        #expect(stillPaused.needsUpdate(after: paused, secondsSince: 30))
        var renamed = playing
        renamed.title = "Other"
        #expect(renamed.needsUpdate(after: playing, secondsSince: 0))
        var faster = playing
        faster.speed = 1.5
        #expect(faster.needsUpdate(after: playing, secondsSince: 0))
    }
}

@MainActor
@Suite("Gestures, media keys and Now Playing through the window", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct PlayerInputIntegrationTests {
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

    private func makeController(nowPlaying: (any NowPlayingCenter)? = nil, bindings: KeyBindings = .standard) throws -> PlayerWindowController {
        try PlayerWindowController(
            model: PlayerModel(configuration: PlayerConfiguration(userAgent: "PlayerKitTests/1.0", logSubsystem: "test.playerkit", playsAudio: false)),
            bindings: bindings,
            nowPlaying: nowPlaying
        )
    }

    @Test("Scrolling over the player changes the volume and seeks")
    func scrolling() async throws {
        let controller = try makeController()
        defer { controller.close() }
        try controller.model.open(PlayableSource(url: TestMedia.multiTrack))
        #expect(await eventually { controller.model.state.phase == .playing && controller.model.state.hasShownFirstFrame })
        controller.model.setPaused(true)
        controller.model.setVolume(50)

        controller.scrolled(right: 0, up: 20, isPrecise: true, began: true)
        #expect(controller.model.state.volume == 55)
        controller.scrolled(right: 0, up: -40, isPrecise: true, began: false)
        #expect(controller.model.state.volume == 45)

        controller.model.seek(to: 5)
        #expect(await eventually { abs(controller.model.state.position - 5) < 0.1 })
        controller.scrolled(right: 24, up: 0, isPrecise: true, began: true)
        #expect(await eventually { abs(controller.model.state.position - 9) < 0.2 })
    }

    @Test("Changed key bindings are the ones the window obeys")
    func customBindings() throws {
        let bindings = KeyBindings.standard.applying(overrides: ["j": "volume:-30", "m": "none"])
        let controller = try makeController(bindings: bindings)
        defer { controller.close() }
        controller.model.setVolume(80)
        #expect(controller.press(KeyChord(.character("j"))))
        #expect(controller.model.state.volume == 50)
        #expect(!controller.press(KeyChord(.character("m"))))
        #expect(!controller.model.state.isMuted)
    }

    @Test("The system is told what is playing when it changes, and its commands reach the player")
    func nowPlaying() async throws {
        let center = FakeNowPlayingCenter()
        let controller = try makeController(nowPlaying: center)
        // Nothing open yet: nothing is shown.
        #expect(center.updates.isEmpty)

        try controller.model.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { center.updates.last??.isPlaying == true && center.updates.last??.duration != nil })
        let first = try #require(center.updates.last ?? nil)
        #expect(first.title == "sdr-h264-1080p.mp4")
        #expect(abs((first.duration ?? 0) - 10) < 0.2)
        #expect(!first.hasNext && !first.hasPrevious)

        // Playing on does not produce a stream of updates.
        let count = center.updates.count
        try await Task.sleep(for: .milliseconds(1200))
        #expect(center.updates.count - count <= 1)

        // The system's pause, seek and play commands.
        center.onCommand?(.setPaused(true))
        #expect(await eventually { center.updates.last??.isPlaying == false })
        center.onCommand?(.seekTo(7))
        #expect(await eventually { abs((center.updates.last??.position ?? 0) - 7) < 0.3 })
        center.onCommand?(.setPaused(false))
        #expect(await eventually { center.updates.last??.isPlaying == true })

        // Closing the player withdraws it from the system's display.
        controller.close()
        #expect(center.updates.last == .some(nil))
        #expect(center.onCommand == nil)
    }
}
