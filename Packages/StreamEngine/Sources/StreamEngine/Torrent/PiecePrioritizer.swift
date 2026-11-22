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
    /// Kept small: the engine fetches urgent pieces in no particular order among themselves,
    /// so a long urgent stretch is a stretch that arrives scrambled (measured: with 8 MB urgent
    /// and 256 KiB pieces, the first piece could be the twenty-eighth to arrive).
    public var urgentBytes: Int64
    /// Bytes after those that are fetched as well, of a file that is not fetched whole.
    public var readAheadBytes: Int64
    /// Bytes at each end of the file wanted before playback starts: containers keep their
    /// index there, and the player asks for it before the first frame.
    public var edgeBytes: Int64
    /// Milliseconds between the deadlines of neighbouring urgent pieces.
    public var deadlineStep: Int
    /// At most this many places are served at once; older readers are dropped first.
    public var maximumReaders: Int

    public init(
        urgentBytes: Int64 = 1 << 20,
        readAheadBytes: Int64 = 256 << 20,
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

/// What to ask the torrent engine for: which pieces are needed by when, and which of the
/// file's other pieces are fetched at all.
///
/// The engine fetches a torrent's pieces in file order (`sequential_download`), which is the
/// order a film is watched in. A plan therefore says little: which pieces are not wanted
/// (everything behind the player, until what lies ahead is there), and which few jump the
/// queue because something is waiting for them this moment.
public struct PiecePlan: Sendable, Equatable {
    public enum Priority: Int, Sendable, Comparable {
        /// Not fetched: behind the player while there is still something to fetch ahead of
        /// it, or beyond what is kept of a file too large to keep whole.
        case skip = 0
        /// Fetched in file order, after everything ahead of the player is there.
        case low = 1
        /// Fetched in file order.
        case normal = 4
        /// Fetched before anything else: what a reader is waiting for. These are the pieces
        /// with deadlines; among themselves they come in no particular order, so they are few.
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
/// From the earliest place the player reads from, the file is fetched in order: the megabyte a
/// reader is waiting for jumps the queue and has a deadline (the engine asks several peers for
/// a block that is late), and the rest follows in file order. Nothing behind the player is fetched while anything ahead of it is missing: a
/// connection that is only just fast enough must not spend itself on what was skipped over.
/// Before the player has asked for anything, both ends of the file come first, because that is
/// where containers keep the index the player reads before the first frame.
public enum PiecePrioritizer {
    /// The pieces fetched before the player has asked for anything: both ends of the file.
    public static func edgePieces(map: PieceMap, window: StreamingWindow = StreamingWindow()) -> Set<Int> {
        guard map.fileSize > 0 else { return [] }
        var pieces = Set(map.piece(containing: 0) ... map.piece(containing: window.edgeBytes - 1))
        if map.fileSize > window.edgeBytes {
            pieces.formUnion(map.piece(containing: map.fileSize - window.edgeBytes) ... map.lastPiece)
        }
        return pieces
    }

    /// - Parameters:
    ///   - readers: Offsets within the file that are being read, most recently active first.
    ///   - fetchesWholeFile: Whether the rest of the file is fetched as well. `false` keeps to
    ///     what the player is about to need, for files larger than the cache allows.
    ///   - isComplete: Whether a piece has been downloaded and verified.
    public static func plan(
        map: PieceMap,
        readers: [Int64],
        window: StreamingWindow = StreamingWindow(),
        fetchesWholeFile: Bool = true,
        isComplete: (Int) -> Bool
    ) -> PiecePlan {
        guard map.fileSize > 0 else { return PiecePlan() }
        let positions = readers.prefix(window.maximumReaders).map { min(max($0, 0), map.fileSize - 1) }
        var plan = PiecePlan()

        func want(_ pieces: ClosedRange<Int>, startingAt firstDeadline: Int) {
            for (step, piece) in pieces.enumerated() where !isComplete(piece) {
                let deadline = firstDeadline + step * window.deadlineStep
                plan.deadlines[piece] = min(plan.deadlines[piece] ?? .max, deadline)
            }
        }

        func raise(_ pieces: ClosedRange<Int>, to priority: PiecePlan.Priority) {
            for piece in pieces where !isComplete(piece) {
                plan.priorities[piece] = max(plan.priorities[piece] ?? .skip, priority)
            }
        }

        // Every missing piece is in the plan, so that the engine is told about each of them.
        raise(map.pieces, to: .skip)

        if positions.isEmpty {
            // Nothing has been asked for yet: get both ends, the start first (`edgePieces`).
            let head = map.piece(containing: 0) ... map.piece(containing: window.edgeBytes - 1)
            want(head, startingAt: 0)
            if map.fileSize > window.edgeBytes {
                want(map.piece(containing: map.fileSize - window.edgeBytes) ... map.lastPiece, startingAt: window.deadlineStep)
            }
            if fetchesWholeFile {
                raise(map.pieces, to: .normal)
            }
        }

        for (rank, position) in positions.enumerated() {
            let first = map.piece(containing: position)
            let lastUrgent = map.piece(containing: position + window.urgentBytes - 1)
            // A reader that has been quiet for a while waits behind the ones in use.
            want(first ... lastUrgent, startingAt: rank * window.deadlineStep * 4)

            let lastAhead = map.piece(containing: position + window.urgentBytes + window.readAheadBytes - 1)
            raise(first ... (fetchesWholeFile ? map.lastPiece : max(lastAhead, lastUrgent)), to: .normal)
        }

        // What was skipped over comes last, and only for a file that is kept whole.
        let earliest = positions.map { map.piece(containing: $0) }.min() ?? map.firstPiece
        if fetchesWholeFile, earliest > map.firstPiece, (earliest ... map.lastPiece).allSatisfy(isComplete) {
            raise(map.firstPiece ... earliest - 1, to: .low)
        }
        // A piece with a deadline jumps the queue (the engine does this by itself; the plan says so too).
        for piece in plan.deadlines.keys {
            plan.priorities[piece] = .high
        }
        return plan
    }
}
