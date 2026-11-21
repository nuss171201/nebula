import Foundation
import Observation

public extension PlayerModel {
    /// What the player is doing.
    ///
    /// The playhead moves about fifteen times a second and the buffer about as often. If those
    /// counted as changes to `state`, every view that reads anything from it (the whole player
    /// view does) would be evaluated and laid out again at that rate for as long as a video
    /// plays; that was the main thread's largest cost during playback. So a change to the
    /// position or the buffer alone is announced as a change to `playhead` only, and a write
    /// that changes nothing is not announced at all. Views that follow the playhead read
    /// `playhead` (or `displayPosition`); `state.position` is always current but is not a
    /// reason to be told.
    internal(set) var state: PlaybackState {
        get {
            access(keyPath: \.state)
            return storedState
        }
        set {
            let old = storedState
            guard newValue != old else { return }
            var steady = newValue
            steady.position = old.position
            steady.bufferedAhead = old.bufferedAhead
            if steady == old {
                withMutation(keyPath: \.playhead) { storedState = newValue }
                return
            }
            // Not while shutting down: the engine's last words must not ask the Mac to stay awake.
            wakefulness.set(hasShutDown ? .none : Wakefulness.level(for: newValue))
            if newValue.position == old.position {
                withMutation(keyPath: \.state) { storedState = newValue }
            } else {
                withMutation(keyPath: \.state) {
                    withMutation(keyPath: \.playhead) { storedState = newValue }
                }
            }
        }
    }

    /// Where playback is, in seconds. Observed separately from `state`.
    var playhead: Double {
        access(keyPath: \.playhead)
        return storedState.position
    }

    /// Reads an engine property as text. Blocks briefly; for diagnostics and tests only.
    func engineProperty(_ name: String) -> String? {
        client.string(name)
    }

    /// Runs an engine command and returns its result. Blocks; for tests and off-main work.
    internal func engineCommandResult(_ arguments: [String]) -> MPVNode? {
        client.commandResult(arguments)
    }
}

// MARK: - Events as they are passed on

extension PlayerModel {
    /// Adds an event to `eventTrace`, if tracing is on, with the milliseconds since the player
    /// was made; at the moments that matter, also where the engine itself says it is.
    func trace(_ event: PlayerEvent) {
        guard eventTrace != nil else { return }
        if event.isWorthTracing {
            let milliseconds = Int((ContinuousClock.now - traceStart) / .milliseconds(1))
            eventTrace?.append("\(milliseconds):\(event.traceDescription)")
        }
        if event == .playbackRestarted || event == .fileLoaded || event == .property(.reachedEnd(true)) {
            let details = ["time-pos", "aid", "current-ao", "audio-pts", "pause", "speed"]
                .map { "\($0)=\(client.string($0) ?? "-")" }
                .joined(separator: " ")
            eventTrace?.append("[\(details)]")
        }
    }

    /// The event as the rest of the player should see it. A stream that never arrived is not
    /// "a file in an unknown format", whatever the engine makes of an empty file.
    func inOurWords(_ event: PlayerEvent) -> PlayerEvent {
        guard case let .ended(.failed(reason)) = event else { return event }
        return .ended(.failed(PlaybackOptions.failureMessage(
            engine: reason,
            arrival: source.flatMap { arrivalFailureMessages[$0.engineArgument] },
            hadOpened: state.hasMedia,
            waited: openedAt.map { ContinuousClock.now - $0 }
        )))
    }
}
