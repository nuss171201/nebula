import Foundation

/// Where one file sits among a torrent's pieces. Offsets given to its methods are within the file.
public struct PieceMap: Sendable, Equatable {
    /// Bytes per piece (the torrent's last piece may be shorter).
    public let pieceLength: Int64
    /// Where the file starts, counted from the start of the torrent's data.
    public let fileOffset: Int64
    public let fileSize: Int64

    public init(pieceLength: Int64, fileOffset: Int64, fileSize: Int64) {
        self.pieceLength = max(pieceLength, 1)
        self.fileOffset = max(fileOffset, 0)
        self.fileSize = max(fileSize, 0)
    }

    public var firstPiece: Int {
        Int(fileOffset / pieceLength)
    }

    /// The last piece holding any of the file. Equal to `firstPiece` for an empty file.
    public var lastPiece: Int {
        Int((fileOffset + max(fileSize, 1) - 1) / pieceLength)
    }

    public var pieces: ClosedRange<Int> {
        firstPiece ... lastPiece
    }

    /// The piece holding the file's byte at `offset`, clamped to the file.
    public func piece(containing offset: Int64) -> Int {
        let clamped = min(max(offset, 0), max(fileSize - 1, 0))
        return Int((fileOffset + clamped) / pieceLength)
    }

    /// The part of the file a piece holds, as offsets within the file. Empty for pieces outside it.
    public func fileRange(ofPiece piece: Int) -> Range<Int64> {
        let start = Int64(piece) * pieceLength - fileOffset
        let lower = min(max(start, 0), fileSize)
        let upper = min(max(start + pieceLength, 0), fileSize)
        return lower ..< max(lower, upper)
    }

    /// Where in a piece's own bytes the file's byte at `offset` is.
    public func offsetInPiece(of offset: Int64) -> Int {
        Int((fileOffset + offset) % pieceLength)
    }
}

/// How much is fetched around each place the player is reading from.
public struct StreamingWindow: Sendable, Equatable {
    /// Bytes from a reader's position that are wanted at once, each piece with a deadline.
    public var urgentBytes: Int64
    /// Bytes after those that are fetched ahead of the rest of the file.
    public var readAheadBytes: Int64
    /// Bytes at each end of the file wanted before playback starts: containers keep their
    /// index there, and the player asks for it before the first frame.
    public var edgeBytes: Int64
    /// Milliseconds between the deadlines of neighbouring urgent pieces.
    public var deadlineStep: Int
    /// At most this many places are served at once; older readers are dropped first.
    public var maximumReaders: Int

    public init(
        urgentBytes: Int64 = 8 << 20,
        readAheadBytes: Int64 = 48 << 20,
        edgeBytes: Int64 = 2 << 20,
        deadlineStep: Int = 250,
        maximumReaders: Int = 3
    ) {
        self.urgentBytes = max(urgentBytes, 1)
        self.readAheadBytes = max(readAheadBytes, 0)
        self.edgeBytes = max(edgeBytes, 0)
        self.deadlineStep = max(deadlineStep, 1)
        self.maximumReaders = max(maximumReaders, 1)
    }
}

/// What to ask the torrent engine for: which pieces are needed by when, and how keen to be
/// about every other piece of the file.
public struct PiecePlan: Sendable, Equatable {
    public enum Priority: Int, Sendable, Comparable {
        /// Behind the player: fetched when nothing else is wanted, for seeking back.
        case low = 1
        /// Ahead of the player, but not soon.
        case normal = 4
        /// Just beyond the urgent window.
        case high = 7

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Milliseconds from now by which each urgent piece is wanted. Pieces already complete are left out.
    public var deadlines: [Int: Int]
    /// Every missing piece of the file, urgent ones included.
    public var priorities: [Int: Priority]

    public init(deadlines: [Int: Int] = [:], priorities: [Int: Priority] = [:]) {
        self.deadlines = deadlines
        self.priorities = priorities
    }

    /// What has to be told to the engine to get from an earlier plan to this one.
    public struct Changes: Sendable, Equatable {
        public var deadlinesToSet: [Int: Int] = [:]
        public var deadlinesToClear: [Int] = []
        public var prioritiesToSet: [Int: Priority] = [:]

        public var isEmpty: Bool {
            deadlinesToSet.isEmpty && deadlinesToClear.isEmpty && prioritiesToSet.isEmpty
        }
    }

    public func changes(from previous: PiecePlan) -> Changes {
        var changes = Changes()
        for (piece, deadline) in deadlines where previous.deadlines[piece] != deadline {
            changes.deadlinesToSet[piece] = deadline
        }
        changes.deadlinesToClear = previous.deadlines.keys.filter { deadlines[$0] == nil }.sorted()
        for (piece, priority) in priorities where previous.priorities[piece] != priority {
            changes.prioritiesToSet[piece] = priority
        }
        return changes
    }
}

/// Decides which pieces of a file to fetch first so that it can be played while it downloads.
///
/// Around each place the player reads from: the next few megabytes are urgent, with deadlines
/// that rise piece by piece so they arrive in order; the stretch after that is fetched ahead
/// of everything else; the rest of the file ahead comes at normal priority and what lies
/// behind at low priority. Before the player has asked for anything, both ends of the file
/// are urgent, because that is where containers keep the index the player reads first.
public enum PiecePrioritizer {
    /// - Parameters:
    ///   - readers: Offsets within the file that are being read, most recently active first.
    ///   - isComplete: Whether a piece has been downloaded and verified.
    public static func plan(
        map: PieceMap,
        readers: [Int64],
        window: StreamingWindow = StreamingWindow(),
        isComplete: (Int) -> Bool
    ) -> PiecePlan {
        guard map.fileSize > 0 else { return PiecePlan() }
        let readers = Array(readers.prefix(window.maximumReaders))
        var plan = PiecePlan()

        func want(_ pieces: ClosedRange<Int>, startingAt firstDeadline: Int) {
            for (step, piece) in pieces.enumerated() where !isComplete(piece) {
                let deadline = firstDeadline + step * window.deadlineStep
                plan.deadlines[piece] = min(plan.deadlines[piece] ?? .max, deadline)
            }
        }

        func raise(_ pieces: ClosedRange<Int>, to priority: PiecePlan.Priority) {
            for piece in pieces where !isComplete(piece) {
                plan.priorities[piece] = max(plan.priorities[piece] ?? .low, priority)
            }
        }

        // Everything missing starts low; the stretches that matter are raised below.
        raise(map.pieces, to: .low)

        if readers.isEmpty {
            // Nothing has been asked for yet: get both ends, the start first.
            want(map.piece(containing: 0) ... map.piece(containing: window.edgeBytes - 1), startingAt: 0)
            if map.fileSize > window.edgeBytes {
                want(map.piece(containing: map.fileSize - window.edgeBytes) ... map.lastPiece, startingAt: window.deadlineStep)
            }
            raise(map.pieces, to: .normal)
        }

        for (rank, reader) in readers.enumerated() {
            let position = min(max(reader, 0), map.fileSize - 1)
            let first = map.piece(containing: position)
            let lastUrgent = map.piece(containing: position + window.urgentBytes - 1)
            // A reader that has been quiet for a while waits behind the ones in use.
            want(first ... lastUrgent, startingAt: rank * window.deadlineStep * 4)

            if lastUrgent < map.lastPiece, window.readAheadBytes > 0 {
                let lastAhead = map.piece(containing: position + window.urgentBytes + window.readAheadBytes - 1)
                raise(lastUrgent + 1 ... max(lastAhead, lastUrgent + 1), to: .high)
            }
            raise(first ... map.lastPiece, to: .normal)
        }
        // Urgent pieces are also the keenest in the ordinary ordering.
        for piece in plan.deadlines.keys {
            plan.priorities[piece] = .high
        }
        return plan
    }
}
