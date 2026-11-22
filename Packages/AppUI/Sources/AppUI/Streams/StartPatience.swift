import Foundation
import PlayerKit
import StreamEngine

/// How long Play stays with a stream it chose before it tries the next one.
///
/// A fixed time was wrong for torrents. A film's pieces are 4 to 16 MiB, the player needs both
/// ends of the file before it can show anything, and a swarm takes its time to gather: in the
/// user's own log a film with 60 seeds gave 450 kB/s for its first minute and 5 MB/s after it.
/// Thirty seconds were up while it was arriving, the next stream began from nothing, and three
/// streams in a row were given up on for a film that started by itself when simply left alone.
/// So what counts is whether anything is arriving, not how long it has been.
struct StartPatience: Sendable, Equatable {
    /// With nothing arriving for this long, the stream is given up on.
    var quiet: Duration
    /// While another stream is still to be tried, this is the longest one may take to start.
    var limit: Duration

    static let torrent = StartPatience(quiet: .seconds(30), limit: .seconds(180))
    /// A web address says nothing about what is arriving, so its time is simply a time.
    static let direct = StartPatience(quiet: .seconds(20), limit: .seconds(20))

    /// - Parameters:
    ///   - waited: Since the stream was started.
    ///   - sinceArrival: Since something of what the player waits for last arrived; `nil` if nothing has.
    ///   - secondsLeft: How long the rest of it should take at the pace it is coming, if that is known.
    ///   - othersToTry: Whether giving up leads anywhere. The last stream is left to arrive
    ///     however slowly: the alternative is telling the user that nothing would start.
    func isUp(waited: Duration, sinceArrival: Duration?, secondsLeft: Double?, othersToTry: Bool) -> Bool {
        if min(sinceArrival ?? waited, waited) >= quiet {
            return true
        }
        guard othersToTry else { return false }
        if waited >= limit {
            return true
        }
        // A trickle is arriving too, and would be waited for to the limit. Once the quiet time
        // has passed, a stream that cannot make the limit at its pace is left at once.
        if waited >= quiet, let secondsLeft, waited + .seconds(secondsLeft) > limit {
            return true
        }
        return false
    }
}

/// What Play has seen arrive of the stream it is waiting on.
struct ArrivalSigns: Sendable, Equatable {
    /// When something last arrived.
    private(set) var lastArrival: ContinuousClock.Instant?
    /// How long what is still waited for should take; `nil` when nothing is coming.
    private(set) var secondsLeft: Double?
    private var bytesDone: Int64 = 0
    /// The first reading, which the pace since then is worked out from.
    private var first: (bytes: Int64, at: ContinuousClock.Instant)?

    static func == (lhs: ArrivalSigns, rhs: ArrivalSigns) -> Bool {
        lhs.lastArrival == rhs.lastArrival && lhs.secondsLeft == rhs.secondsLeft && lhs.bytesDone == rhs.bytesDone
    }

    /// The torrent's description came: somebody is there.
    mutating func noteDescription(at now: ContinuousClock.Instant) {
        lastArrival = now
    }

    /// Takes the engine's reading of what the player waits for.
    /// - Parameter rate: The torrent's download rate at this moment, bytes a second.
    mutating func note(_ arrival: ArrivalProgress?, rate: Int, at now: ContinuousClock.Instant) {
        guard let arrival else { return }
        if arrival.bytesDone > bytesDone {
            lastArrival = now
        } else if arrival.bytesDone < bytesDone {
            // The engine began counting again (the player stalled anew): so does the pace.
            first = nil
        }
        bytesDone = arrival.bytesDone
        let start = first ?? (arrival.bytesDone, now)
        first = start
        // The better of the rate right now and the pace so far: a swarm speeds up as it gathers,
        // so the pace alone is too gloomy, and one slow reading alone says little.
        let elapsed = (now - start.at) / .seconds(1)
        let pace = elapsed >= 1 ? Double(arrival.bytesDone - start.bytes) / elapsed : 0
        let speed = max(Double(rate), pace)
        secondsLeft = speed > 0 ? Double(arrival.bytesLeft) / speed : nil
    }
}

extension StreamPlayer {
    /// Waiting as the person sees it. The engine stops calling itself busy once it has read a
    /// file's headers, but the busy indicator stays up until there is a picture, and a torrent
    /// can take most of its starting time between the two.
    nonisolated static func isWaiting(_ state: PlaybackState) -> Bool {
        state.isBusy || (state.phase == .playing && !state.hasShownFirstFrame && !state.isAudioOnly)
    }
}
