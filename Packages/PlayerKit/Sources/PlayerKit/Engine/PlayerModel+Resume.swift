import Foundation

/// What the player keeps track of to carry on where the user left off.
struct ResumeState {
    /// Seconds from either end of a file inside which there is nothing worth resuming.
    static let margin = 10.0
    /// How far playback moves between saves.
    static let saveInterval = 10.0

    /// The name the open file's position is stored under.
    var key: String?
    /// The position last written, to save only when it has moved on.
    var lastSaved: Double?

    /// What to store for a file left at `position`: the position, or `nil` (forget it) when the
    /// file has only just begun or is as good as finished.
    static func positionWorthKeeping(_ position: Double, duration: Double?) -> Double? {
        guard position >= margin else { return nil }
        if let duration, position > duration - max(margin, duration * 0.03) {
            return nil
        }
        return position
    }
}

/// Remembering where each file was left, and going back there when it is opened again.
extension PlayerModel {
    /// When a file has loaded: go to where it was left last time, if anywhere.
    func restorePosition(generation: Int) async {
        guard resumesPlayback, let memory, let key = currentMemoryKeys.first else { return }
        resume = ResumeState(key: key)
        guard let position = await memory.rememberedPosition(for: key), generation == fileGeneration else { return }
        // Recorded with a margin from both ends, but the file may have changed since.
        guard position >= ResumeState.margin, state.duration.map({ position < $0 - 1 }) ?? true else { return }
        resume.lastSaved = position
        seek(to: position)
        announce("Resumed at \(PlaybackTime.format(position))")
    }

    /// Called as the playhead moves: saves now and then, so little is lost if the app goes away.
    func savePositionIfDue() {
        guard resume.key != nil, state.phase == .playing, !state.isSeeking else { return }
        if abs(state.position - (resume.lastSaved ?? 0)) >= ResumeState.saveInterval {
            savePosition()
        }
    }

    /// Stores where the open file is now. Called when pausing, and before leaving the file.
    func savePosition() {
        guard let memory, let key = resume.key, state.hasMedia else { return }
        let position = state.phase == .ended ? nil : ResumeState.positionWorthKeeping(state.position, duration: state.duration)
        resume.lastSaved = position ?? state.position
        Task {
            await memory.remember(position: position, for: key)
        }
    }
}
