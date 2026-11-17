import Foundation
@testable import PlayerKit
import Testing

@MainActor
@Suite("Keeping the Mac awake while playing")
struct WakefulnessTests {
    private func state(
        phase: PlaybackState.Phase = .playing,
        paused: Bool = false,
        waiting: Bool = false,
        tracks: [MediaTrack]
    ) -> PlaybackState {
        var state = PlaybackState()
        state.phase = phase
        state.isPaused = paused
        state.isWaitingForData = waiting
        state.tracks = tracks
        return state
    }

    private let video = MediaTrack(kind: .video, number: 1, isSelected: true)
    private let audio = MediaTrack(kind: .audio, number: 1, isSelected: true)

    @Test("A picture keeps the display on; sound alone keeps the Mac awake; anything not playing asks for nothing")
    func levels() {
        #expect(Wakefulness.level(for: state(tracks: [video, audio])) == .display)
        // Waiting for the network in the middle of a film is still watching a film.
        #expect(Wakefulness.level(for: state(waiting: true, tracks: [video, audio])) == .display)
        #expect(Wakefulness.level(for: state(tracks: [audio])) == .system)
        // The mini player switches the picture off; a cover picture is not a film.
        #expect(Wakefulness.level(for: state(tracks: [MediaTrack(kind: .video, number: 1, isSelected: false), audio])) == .system)
        #expect(Wakefulness.level(for: state(tracks: [MediaTrack(kind: .video, number: 1, isSelected: true, isCoverArt: true), audio])) == .system)
        #expect(Wakefulness.level(for: state(paused: true, tracks: [video, audio])) == .none)
        #expect(Wakefulness.level(for: state(phase: .ended, tracks: [video, audio])) == .none)
        #expect(Wakefulness.level(for: state(phase: .loading, tracks: [])) == .none)
        #expect(Wakefulness.level(for: PlaybackState()) == .none)
    }

    private final class Token: NSObject {}

    @Test("The system is asked once per change of level, and every request is handed back")
    func holder() {
        var begun: [Wakefulness.Level] = []
        var ended = 0
        let wakefulness = Wakefulness(begin: { level in
            begun.append(level)
            return Token()
        }, end: { _ in
            ended += 1
        })
        wakefulness.set(.none)
        #expect(begun.isEmpty)
        wakefulness.set(.display)
        wakefulness.set(.display)
        #expect(begun == [.display])
        #expect(ended == 0)
        wakefulness.set(.system)
        #expect(begun == [.display, .system])
        #expect(ended == 1)
        wakefulness.set(.none)
        #expect(ended == 2)
        #expect(wakefulness.level == .none)
    }

    @Test(
        "A playing file holds the display awake; pausing and closing let go",
        .enabled(if: FileManager.default.fileExists(atPath: TestMedia.sdr.path), "run Scripts/make-test-media.sh first")
    )
    func player() async throws {
        let player = try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .none,
            playsAudio: false
        ))
        #expect(player.wakefulness.level == .none)
        try player.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { player.wakefulness.level == .display })
        player.setPaused(true)
        #expect(await eventually { player.wakefulness.level == .none })
        player.setPaused(false)
        #expect(await eventually { player.wakefulness.level == .display })
        player.shutdown()
        #expect(player.wakefulness.level == .none)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 400 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
