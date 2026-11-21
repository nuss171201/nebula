import Foundation

/// What this Mac's player is doing, as the party needs to know it.
public struct PlaybackSnapshot: Sendable, Equatable {
    /// What is open (or being opened); `nil` when there is no player.
    public var content: PartyContent?
    /// Whether the file is open: playing, paused or sitting on its last frame.
    public var hasMedia: Bool
    public var isPaused: Bool
    /// Whether the picture cannot advance right now: waiting for data, or in the middle of a seek.
    public var isStalled: Bool
    /// Whether playback has reached the end of the file.
    public var hasEnded: Bool
    public var position: Double
    public var duration: Double?
    /// The speed the user has chosen, without the small corrections the party makes.
    public var rate: Double

    public init(
        content: PartyContent? = nil,
        hasMedia: Bool = false,
        isPaused: Bool = false,
        isStalled: Bool = false,
        hasEnded: Bool = false,
        position: Double = 0,
        duration: Double? = nil,
        rate: Double = 1
    ) {
        self.content = content
        self.hasMedia = hasMedia
        self.isPaused = isPaused
        self.isStalled = isStalled
        self.hasEnded = hasEnded
        self.position = position
        self.duration = duration
        self.rate = rate
    }

    /// No player open.
    public static let none = PlaybackSnapshot()
}

/// Something the party asks this Mac's player to do.
public enum PlayerDirective: Sendable, Equatable {
    case setPaused(Bool)
    /// Seconds from the start.
    case seek(to: Double)
    /// The speed everyone plays at.
    case setRate(Double)
    /// A factor close to 1 on top of that speed, to catch up or fall back without a jump.
    case adjustRate(Double)
}

/// Something the person at this Mac did with their player.
public enum LocalIntent: Sendable, Equatable {
    case setPaused(Bool)
    /// A jump of theirs has landed; where is in the snapshot.
    case seeked
    case rate(Double)
}

/// This Mac's player, as the party sees it. Implemented by the app.
@MainActor
public protocol PartyPlayback: AnyObject {
    var snapshot: PlaybackSnapshot { get }
    /// Does what the party asks. Must not be reported back through `onIntent`.
    func apply(_ directive: PlayerDirective)
    /// Called when the person at this Mac pauses, resumes, jumps or changes speed themselves.
    var onIntent: (@MainActor (LocalIntent) -> Void)? { get set }
    /// Shows a short message over the picture.
    func showNotice(_ text: String)
}

/// The numbers that decide how players are kept together.
public enum SyncTuning {
    /// How far apart two paused players may be before one is moved. Tight, because people pause
    /// to look at something together, and a jump while paused costs nothing.
    public static let pausedTolerance = 0.1
    /// Further out of step than this is put right with a jump; less, by playing slightly faster or slower.
    public static let jumpThreshold = 1.5
    /// How long to wait after a jump before judging whether another is needed.
    public static let jumpCooldown = 2.0
    /// How long a player that was in step may stall before the party pauses for it.
    public static let stallBeforeHold = 1.5
    /// How long a stall lasts before it is reported to the others.
    public static let stallBeforeReport = 0.7
    /// The shortest time the party stays paused once it has paused for someone.
    public static let minimumHold = 0.5
    /// How often each app tells the others what its player is doing, when nothing changes.
    public static let statusInterval = 2.0

    /// The speed factor that closes a gap of `delta` seconds (positive: ahead of the party).
    ///
    /// A gap under an eighth of a second is left alone, since chasing it would mean changing speed
    /// all the time; once a correction has started it runs until the gap is nearly closed.
    public static func rateAdjustment(forGap delta: Double, current: Double) -> Double {
        let gap = abs(delta)
        if gap < 0.03 || (current == 1 && gap < 0.12) {
            return 1
        }
        let correction = min(max(-delta * 0.25, -0.08), 0.08)
        return ((1 + correction) * 100).rounded() / 100
    }
}
