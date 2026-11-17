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
