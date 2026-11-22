import Foundation

/// Works out how far another Mac's clock is from this one, from clock readings sent there and
/// straight back.
///
/// Each exchange gives one estimate, which is off by at most half of the time the exchange took;
/// the estimate from the quickest recent exchange is the one that is used.
public struct ClockSync: Sendable, Equatable {
    private struct Sample: Sendable, Equatable {
        var roundTrip: TimeInterval
        var offset: TimeInterval
    }

    private var samples: [Sample] = []
    private static let kept = 8

    public init() {}

    /// The other clock minus this one, in seconds; `nil` until an exchange has completed.
    public var offset: TimeInterval? {
        best?.offset
    }

    /// How long the quickest recent exchange took, there and back.
    public var roundTrip: TimeInterval? {
        best?.roundTrip
    }

    private var best: Sample? {
        samples.min { $0.roundTrip < $1.roundTrip }
    }

    /// Records one exchange: a reading taken here at `sentAt` came back at `receivedAt`, and the
    /// other clock read `remoteAt` when it turned it round.
    public mutating func addSample(sentAt: TimeInterval, remoteAt: TimeInterval, receivedAt: TimeInterval) {
        let roundTrip = receivedAt - sentAt
        // An answer from before its question, or one that took this long, tells nothing useful.
        guard roundTrip >= 0, roundTrip < 10, remoteAt.isFinite else { return }
        samples.append(Sample(roundTrip: roundTrip, offset: remoteAt - (sentAt + roundTrip / 2)))
        if samples.count > Self.kept {
            samples.removeFirst(samples.count - Self.kept)
        }
    }
}
