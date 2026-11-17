import Foundation

/// Keeps the Mac awake while something plays.
///
/// The engine would do this for a window of its own; it draws into the app's layer, so the app
/// has to. Without it the display dims and sleeps in the middle of a film, and macOS treats a
/// player that is not the front window as idle and slows its timers until frames are dropped.
@MainActor
final class Wakefulness {
    enum Level: Equatable, Sendable {
        /// Nothing is playing: the Mac may do as it likes.
        case none
        /// Sound is playing: the Mac stays awake, the display may sleep.
        case system
        /// A picture is playing: the display stays on too.
        case display
    }

    private(set) var level = Level.none
    private var token: (any NSObjectProtocol)?
    private let begin: (Level) -> (any NSObjectProtocol)?
    private let end: (any NSObjectProtocol) -> Void

    /// - Parameters:
    ///   - begin: Asks the system to stay awake at a level; the result is handed back to `end`.
    init(
        begin: @escaping (Level) -> (any NSObjectProtocol)? = Wakefulness.beginSystemActivity,
        end: @escaping (any NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    /// What a player in this state needs. Paused, ended or idle needs nothing; a stall for data
    /// in the middle of playing still counts as playing.
    static func level(for state: PlaybackState) -> Level {
        guard state.phase == .playing, !state.isPaused else { return .none }
        let showsPicture = state.tracks.contains { $0.kind == .video && $0.isSelected && !$0.isCoverArt }
        return showsPicture ? .display : .system
    }

    func set(_ newLevel: Level) {
        guard newLevel != level else { return }
        if let token {
            end(token)
        }
        level = newLevel
        token = newLevel == .none ? nil : begin(newLevel)
    }

    nonisolated static func beginSystemActivity(_ level: Level) -> (any NSObjectProtocol)? {
        switch level {
        case .none:
            nil
        case .system:
            ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Playing audio")
        case .display:
            ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Playing video")
        }
    }
}
