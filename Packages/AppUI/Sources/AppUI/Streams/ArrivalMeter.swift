import Foundation
import StreamEngine

/// Turns the engine's readings of what the player is waiting for into what the busy
/// indicator shows: a fraction that never goes backward while the player sits there, and how
/// long the rest should take.
///
/// The engine counts the pieces a reader has had to wait for. That list grows while the player
/// opens a file (the start, then the index at the end), and a longer list is a smaller
/// fraction; a percentage that drops reads as something having gone wrong, so the highest
/// one shown so far is kept until the player has stopped waiting.
struct ArrivalMeter: Sendable, Equatable {
    /// What was shown last; `nil` before the first reading.
    private(set) var shown: Double?

    /// The player is no longer waiting: the next wait starts from nothing.
    mutating func reset() {
        shown = nil
    }

    /// Takes a reading and returns the fraction to show. A missing reading (nothing is being
    /// waited for at this instant) keeps what was there.
    mutating func read(_ arrival: ArrivalProgress?) -> Double? {
        guard let arrival else { return shown }
        shown = max(shown ?? 0, arrival.fraction)
        return shown
    }

    /// "about 25 s left", from what is still to come and how fast it is coming. `nil` when
    /// nothing is coming, or when so little is left that a figure would be out of date at once.
    static func timeLeft(bytes: Int64, rate: Int) -> String? {
        guard bytes > 0, rate > 0 else { return nil }
        let seconds = Double(bytes) / Double(rate)
        switch seconds {
        case ..<3: return nil
        case ..<10: return "a few seconds left"
        // To the nearest five: the rate moves about, and a figure that changes every reading is noise.
        case ..<90: return "about \(Int((seconds / 5).rounded()) * 5) s left"
        case ..<3600: return "about \(Int((seconds / 60).rounded())) min left"
        default: return "over an hour left"
        }
    }
}
