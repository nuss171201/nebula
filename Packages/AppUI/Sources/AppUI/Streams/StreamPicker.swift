import Foundation
import PlayerKit

/// One stream as the picker sees it: what it would need, and how suitable that makes it.
public struct StreamPick: Sendable, Equatable, Identifiable {
    /// From most to least suitable. A stream's place in the list is decided by this first.
    public enum Standing: Int, Sendable, Comparable {
        /// Should play without waiting: the connection can keep up, the language is right,
        /// and (for a torrent) enough people share it.
        case good
        /// The connection could keep up, but it is more than a film needs to look good, and
        /// what it costs is the wait: large files come in large pieces and start slowly.
        case large
        /// As good, except that few people share it, so it may be slow to start.
        case fewPeers
        /// Needs more than the connection is known to give: it would stop to load.
        case tooHeavy
        /// Over the quality or size the user allows.
        case overLimit
        /// In a language the user did not ask for.
        case wrongLanguage

        public static func < (lhs: Standing, rhs: Standing) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let choice: StreamChoice
    public let facts: StreamFacts
    public let standing: Standing
    /// Bytes a second it takes to play without stopping, when that can be worked out.
    public let requiredSpeed: Double?

    public var id: String { choice.id }

    /// One line on what was picked: "1080p · 18.7 GB · 207 sharing".
    public var summary: String {
        var parts: [String] = []
        if let quality = choice.quality {
            parts.append(quality.label)
        }
        if let size = choice.sizeText {
            parts.append(size)
        }
        if choice.kind == .torrent, let peers = facts.peers {
            parts.append("\(peers) sharing")
        }
        return parts.isEmpty ? choice.addonName : parts.joined(separator: " · ")
    }
}

/// Chooses the stream to play when the user just presses Play.
///
/// A list of forty streams with release names is a question most people cannot answer, and
/// the wrong answer (an 80 GB disc copy on a home connection) only shows up as a film that
/// keeps stopping. The picker answers it from what the list itself says: what each stream
/// would need (its size over the running time), how fast this connection has been seen to
/// be, which languages it speaks, and how many people share it. Of what would play, it takes
/// the best picture of a modest size, not the largest file. Pure: same inputs, same answer.
public enum StreamPicker {
    public struct Context: Sendable, Equatable {
        /// How long the title runs, in seconds, when the catalog says.
        public var runtime: Double?
        /// The fastest this connection has been seen to download, in bytes a second; `nil` before anything was measured.
        public var measuredSpeed: Double?
        /// The languages the user wants to hear, most wanted first.
        public var languages: [String]
        /// Nothing above this is picked; `nil` for no limit.
        public var maximumQuality: StreamQuality?
        /// Nothing larger than this is picked; `nil` for no limit.
        public var maximumSize: Int64?
        /// What was played for this title last time.
        public var lastChoice: LastStreamChoice?

        public init(
            runtime: Double? = nil,
            measuredSpeed: Double? = nil,
            languages: [String] = [],
            maximumQuality: StreamQuality? = nil,
            maximumSize: Int64? = nil,
            lastChoice: LastStreamChoice? = nil
        ) {
            self.runtime = runtime
            self.measuredSpeed = measuredSpeed
            self.languages = languages
            self.maximumQuality = maximumQuality
            self.maximumSize = maximumSize
            self.lastChoice = lastChoice
        }
    }

    /// What is assumed of a connection nothing is known about yet: 20 Mbit/s, which a full-HD
    /// film from the web fits in and which most home connections manage. It rises with the first real download.
    public static let assumedSpeed: Double = 2_500_000
    /// The share of the connection a stream may need. The rest is headroom: speed varies,
    /// and a film's busy scenes need more than its average.
    public static let usableShare = 0.7
    /// What Play picks by itself needs no more than this, however fast the connection:
    /// 10 Mbit/s, about 8 GB for a two-hour film. Above it the picture gains little and the
    /// start loses a lot. The user's own session showed it: a 21 GB film, well within what the
    /// connection had managed the day before, took over two minutes to show a picture, because
    /// its pieces are 16 MiB each, the player needs three of them first, and a swarm gives a
    /// few hundred kilobytes a second for its first minute. Larger streams stay in the list.
    public static let comfortableSpeed: Double = 1_250_000
    /// Fewer people than this sharing a torrent and it is likely to start slowly or not at all.
    public static let healthyPeers = 5
    /// A title's length when the catalog does not give one: a film's.
    static let assumedRuntime: Double = 110 * 60

    /// Streams that can be played by pressing Play, most suitable first. Entries that are
    /// not one playable video (a disc image, a cinema recording, a web page) are left out.
    public static func picks(from choices: [StreamChoice], context: Context) -> [StreamPick] {
        let wanted = Set(context.languages.compactMap(LanguageMatcher.canonical))
        let budget = (context.measuredSpeed ?? assumedSpeed) * usableShare
        let liked = context.lastChoice?.bestMatch(in: choices)?.id

        let picks = choices.compactMap { choice -> StreamPick? in
            guard choice.kind == .torrent || choice.kind == .direct else { return nil }
            let text = [choice.stream.name, choice.stream.details, choice.stream.behaviorHints.filename].compactMap(\.self).joined(separator: "\n")
            let facts = StreamFacts(text: text)
            guard facts.trap == nil else { return nil }
            let required = requiredSpeed(of: choice, runtime: context.runtime)
            let weight: Weight = switch required {
            case let required? where required > budget: .tooHeavy
            case let required? where required > comfortableSpeed: .large
            default: .fine
            }
            let standing = standing(of: choice, facts: facts, weight: weight, wanted: wanted, context: context)
            return StreamPick(choice: choice, facts: facts, standing: standing, requiredSpeed: required)
        }
        // Stable: among equals, the order the add-ons gave them in stands.
        return picks.enumerated().sorted { left, right in
            let (first, second) = (left.element, right.element)
            if first.standing != second.standing {
                return first.standing < second.standing
            }
            switch first.standing {
            case .good, .fewPeers:
                // What was played last time, if it is as suitable as anything, comes first:
                // the next episode should look and sound like the last one.
                if (first.id == liked) != (second.id == liked) {
                    return first.id == liked
                }
                // Among those few people share, one of a modest size has the better chance.
                if isLarge(first) != isLarge(second) {
                    return isLarge(second)
                }
                if first.choice.quality != second.choice.quality {
                    return (first.choice.quality?.rawValue ?? 0) > (second.choice.quality?.rawValue ?? 0)
                }
                if peerRank(first) != peerRank(second) {
                    return peerRank(first) > peerRank(second)
                }
                if first.choice.sizeBytes != second.choice.sizeBytes {
                    return (first.choice.sizeBytes ?? 0) > (second.choice.sizeBytes ?? 0)
                }
            case .large, .tooHeavy, .overLimit, .wrongLanguage:
                // None of these is right; the least demanding is the least wrong.
                if first.requiredSpeed != second.requiredSpeed {
                    return (first.requiredSpeed ?? .greatestFiniteMagnitude) < (second.requiredSpeed ?? .greatestFiniteMagnitude)
                }
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// Bytes a second a stream needs: its size over the running time, or a usual figure for
    /// its quality when the size is not known.
    static func requiredSpeed(of choice: StreamChoice, runtime: Double?) -> Double? {
        if let size = choice.sizeBytes, size > 0 {
            return Double(size) / max(runtime ?? assumedRuntime, 60)
        }
        // Megabits a second that streams of each quality usually run at, in bytes.
        return switch choice.quality {
        case .uhd4K: 3_000_000
        case .qhd1440: 1_800_000
        case .hd1080: 1_000_000
        case .hd720: 500_000
        case .sd: 250_000
        case nil: nil
        }
    }

    /// What a stream needs, set against the connection and against what a film needs.
    private enum Weight {
        case fine, large, tooHeavy
    }

    private static func standing(
        of choice: StreamChoice,
        facts: StreamFacts,
        weight: Weight,
        wanted: Set<String>,
        context: Context
    ) -> StreamPick.Standing {
        // A stream that names its languages, none of them wanted, is the worst miss there is:
        // it plays perfectly and cannot be understood. One that names none is taken on trust.
        if !wanted.isEmpty, !facts.languages.isEmpty, !facts.isMultiLanguage, facts.languages.isDisjoint(with: wanted) {
            return .wrongLanguage
        }
        if let limit = context.maximumQuality, let quality = choice.quality, quality > limit {
            return .overLimit
        }
        if let limit = context.maximumSize, let size = choice.sizeBytes, size > limit {
            return .overLimit
        }
        if weight == .tooHeavy {
            return .tooHeavy
        }
        if choice.kind == .torrent, let peers = facts.peers, peers < healthyPeers {
            return .fewPeers
        }
        return weight == .large ? .large : .good
    }

    private static func isLarge(_ pick: StreamPick) -> Bool {
        (pick.requiredSpeed ?? 0) > comfortableSpeed
    }

    /// Enough people is enough: ten and a thousand both start at once. Unknown counts as enough.
    private static func peerRank(_ pick: StreamPick) -> Int {
        guard pick.choice.kind == .torrent, let peers = pick.facts.peers else { return 2 }
        return peers >= 20 ? 2 : (peers >= healthyPeers ? 1 : 0)
    }
}

/// How fast this connection downloads, learned from the streams it has played.
///
/// No speed test: that needs somebody's server and says little about a torrent. What a
/// stream actually achieved is a floor under what the connection can do, and it is the floor
/// that matters for choosing a stream that will not stop.
public enum ConnectionSpeed {
    /// The estimate after a session whose best sustained rate was `sessionBest`. A faster
    /// session raises it at once; slower ones lower it a tenth at a time, so one bad swarm
    /// does not make the app timid.
    public static func updated(_ previous: Double?, sessionBest: Double) -> Double? {
        guard sessionBest > 0 else { return previous }
        guard let previous else { return sessionBest }
        return max(sessionBest, previous * 0.9)
    }

    /// The best rate held over a few readings in a row, so that a one-second burst does not count.
    public static func bestSustained(_ samples: [Double], window: Int = 5) -> Double {
        guard samples.count >= window, window > 0 else { return 0 }
        var best = 0.0
        for start in 0 ... samples.count - window {
            best = max(best, samples[start ..< start + window].reduce(0, +) / Double(window))
        }
        return best
    }
}
