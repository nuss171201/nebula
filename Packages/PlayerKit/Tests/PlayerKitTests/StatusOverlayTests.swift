@testable import PlayerKit
import Testing

@Suite("The busy indicator's percentage")
struct StatusOverlayTests {
    private func state(_ events: PlayerEvent...) -> PlaybackState {
        var state = PlaybackState()
        events.forEach { state.apply($0) }
        return state
    }

    @Test("The engine's buffer state is read as a fraction, and forgotten with the file")
    func bufferingProgress() {
        #expect(ObservedProperty.cacheBufferingState.property(for: .int(43)) == .bufferingProgress(0.43))
        #expect(ObservedProperty.cacheBufferingState.property(for: nil) == .bufferingProgress(nil))
        #expect(ObservedProperty.cacheBufferingState.name == "cache-buffering-state")

        var playing = state(.startedLoading, .fileLoaded, .property(.bufferingProgress(0.43)))
        #expect(playing.bufferingProgress == 0.43)
        // Out of range is brought back in, not shown as 140 %.
        playing.apply(.property(.bufferingProgress(1.4)))
        #expect(playing.bufferingProgress == 1)
        playing.apply(.startedLoading)
        #expect(playing.bufferingProgress == nil)
    }

    @Test("What the source's fetcher says comes first; the engine's buffer counts only once a file is open")
    func shownProgress() {
        let loading = state(.startedLoading, .property(.bufferingProgress(0.8)))
        // While opening, the engine's figure is about nothing yet.
        #expect(PlayerStatusOverlay.shownProgress(state: loading, sourceProgress: nil) == nil)
        #expect(PlayerStatusOverlay.shownProgress(state: loading, sourceProgress: 0.25) == 0.25)
        #expect(PlayerStatusOverlay.shownProgress(state: loading, sourceProgress: 1.7) == 1)
        #expect(PlayerStatusOverlay.shownProgress(state: loading, sourceProgress: -1) == 0)

        let stalled = state(.startedLoading, .fileLoaded, .property(.waitingForData(true)), .property(.bufferingProgress(0.6)))
        #expect(PlayerStatusOverlay.shownProgress(state: stalled, sourceProgress: nil) == 0.6)
        #expect(PlayerStatusOverlay.shownProgress(state: stalled, sourceProgress: 0.1) == 0.1)
        let unknown = state(.startedLoading, .fileLoaded, .property(.waitingForData(true)))
        #expect(PlayerStatusOverlay.shownProgress(state: unknown, sourceProgress: nil) == nil)
    }

    @Test("The percentage says 100 only when nothing is left to wait for", arguments: [
        (0.0, 0), (0.004, 0), (0.431, 43), (0.989, 98), (0.995, 99), (0.9999, 99), (1.0, 100), (1.3, 100), (-0.2, 0),
    ])
    func percentage(fraction: Double, expected: Int) {
        #expect(PlayerStatusOverlay.percentage(for: fraction) == expected)
    }

    @Test("It says what is happening: opening, getting ready, or buffering in mid-film")
    func headline() {
        let loading = state(.startedLoading)
        #expect(PlayerStatusOverlay.headline(for: loading, hasProgress: false) == "Opening")
        #expect(PlayerStatusOverlay.headline(for: loading, hasProgress: true) == "Getting ready to play")
        // Open, but no picture yet: still getting ready.
        let opened = state(.startedLoading, .fileLoaded, .property(.waitingForData(true)))
        #expect(PlayerStatusOverlay.headline(for: opened, hasProgress: true) == "Getting ready to play")
        let stalled = state(.startedLoading, .fileLoaded, .playbackRestarted, .property(.waitingForData(true)))
        #expect(PlayerStatusOverlay.headline(for: stalled, hasProgress: true) == "Buffering")
        #expect(PlayerStatusOverlay.headline(for: stalled, hasProgress: false) == "Buffering")
    }

    @Test("VoiceOver hears the percentage and what is being waited for")
    func spokenValue() {
        #expect(PlayerStatusOverlay.spokenValue(fraction: 0.431, note: "7 connections · 694 KB/s") == "43 percent, 7 connections · 694 KB/s")
        #expect(PlayerStatusOverlay.spokenValue(fraction: nil, note: "Looking for people sharing this…") == "Looking for people sharing this…")
        #expect(PlayerStatusOverlay.spokenValue(fraction: nil, note: nil).isEmpty)
    }
}
