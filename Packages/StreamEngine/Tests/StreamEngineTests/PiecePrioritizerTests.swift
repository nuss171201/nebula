import Foundation
@testable import StreamEngine
import Testing

@Suite("Mapping a file onto a torrent's pieces")
struct PieceMapTests {
    /// 1 MiB pieces; the file starts 300 KiB into piece 2 and is 10 MiB long.
    private let map = PieceMap(pieceLength: 1 << 20, fileOffset: (2 << 20) + 300 * 1024, fileSize: 10 << 20)

    @Test("A file covers the pieces from the one holding its first byte to the one holding its last")
    func extent() {
        #expect(map.firstPiece == 2)
        #expect(map.lastPiece == 12)
        #expect(map.pieces.count == 11)
        // A file that ends exactly on a piece boundary does not reach into the next piece.
        let aligned = PieceMap(pieceLength: 1000, fileOffset: 2000, fileSize: 3000)
        #expect(aligned.pieces == 2 ... 4)
        let empty = PieceMap(pieceLength: 1000, fileOffset: 2500, fileSize: 0)
        #expect(empty.pieces == 2 ... 2)
    }

    @Test("Offsets in the file find their piece, clamped to the file")
    func pieceLookup() {
        #expect(map.piece(containing: 0) == 2)
        #expect(map.piece(containing: (1 << 20) - 300 * 1024 - 1) == 2)
        #expect(map.piece(containing: (1 << 20) - 300 * 1024) == 3)
        #expect(map.piece(containing: (10 << 20) - 1) == 12)
        #expect(map.piece(containing: 99 << 20) == 12)
        #expect(map.piece(containing: -5) == 2)
        #expect(map.offsetInPiece(of: 0) == 300 * 1024)
        #expect(map.offsetInPiece(of: (1 << 20) - 300 * 1024) == 0)
    }

    @Test("A piece's share of the file is cut off at the file's ends")
    func fileRanges() {
        #expect(map.fileRange(ofPiece: 2) == 0 ..< (1 << 20) - 300 * 1024)
        #expect(map.fileRange(ofPiece: 3) == (1 << 20) - 300 * 1024 ..< (2 << 20) - 300 * 1024)
        #expect(map.fileRange(ofPiece: 12).upperBound == 10 << 20)
        #expect(map.fileRange(ofPiece: 12).count == 300 * 1024)
        #expect(map.fileRange(ofPiece: 1).isEmpty)
        #expect(map.fileRange(ofPiece: 13).isEmpty)
    }
}

@Suite("Which pieces to fetch first")
struct PiecePrioritizerTests {
    /// 100 pieces of 1 MiB, the file being the whole torrent.
    private let map = PieceMap(pieceLength: 1 << 20, fileOffset: 0, fileSize: 100 << 20)
    private let window = StreamingWindow(urgentBytes: 4 << 20, readAheadBytes: 10 << 20, edgeBytes: 2 << 20, deadlineStep: 250, maximumReaders: 2)

    @Test("Before the player asks for anything, both ends of the file are urgent, the start first")
    func beforePlayback() {
        let plan = PiecePrioritizer.plan(map: map, readers: [], window: window) { _ in false }
        #expect(plan.deadlines == [0: 0, 1: 250, 98: 250, 99: 500])
        #expect(plan.priorities[0] == .high && plan.priorities[99] == .high)
        #expect(plan.priorities[50] == .normal)
        #expect(plan.priorities.count == 100)
    }

    @Test("Around the playhead: urgent pieces in order, then a stretch fetched ahead, then the rest; behind is low")
    func aroundThePlayhead() {
        // Reading from the middle of piece 20.
        let plan = PiecePrioritizer.plan(map: map, readers: [(20 << 20) + 500_000], window: window) { _ in false }
        // 4 MiB from mid-piece 20 reaches into piece 24.
        #expect(plan.deadlines == [20: 0, 21: 250, 22: 500, 23: 750, 24: 1000])
        for piece in 25 ... 34 {
            #expect(plan.priorities[piece] == .high, "piece \(piece)")
        }
        #expect(plan.priorities[35] == .normal)
        #expect(plan.priorities[99] == .normal)
        #expect(plan.priorities[19] == .low)
        #expect(plan.priorities[0] == .low)
    }

    @Test("Pieces that are already there are not asked for, and the ones after them keep their place in line")
    func skipsCompletePieces() {
        let have: Set = [20, 22, 30]
        let plan = PiecePrioritizer.plan(map: map, readers: [20 << 20], window: window) { have.contains($0) }
        #expect(plan.deadlines == [21: 250, 23: 750])
        #expect(plan.priorities[30] == nil)
        #expect(plan.priorities[20] == nil)
        #expect(plan.priorities[29] == .high)
    }

    @Test("Near the end of the file the windows stop at the last piece")
    func nearTheEnd() {
        let plan = PiecePrioritizer.plan(map: map, readers: [(98 << 20) + 10], window: window) { _ in false }
        #expect(plan.deadlines == [98: 0, 99: 250])
        #expect(plan.priorities.values.filter { $0 == .high }.count == 2)
        // A reader past the end is treated as at the last byte.
        let beyond = PiecePrioritizer.plan(map: map, readers: [500 << 20], window: window) { _ in false }
        #expect(beyond.deadlines == [99: 0])
    }

    @Test("Two places are served at once, the active one first; a third is ignored")
    func severalReaders() {
        // The player reads the index at the end while playing from piece 10; an old reader sits at 50.
        let plan = PiecePrioritizer.plan(map: map, readers: [10 << 20, 99 << 20, 50 << 20], window: window) { _ in false }
        #expect(plan.deadlines[10] == 0 && plan.deadlines[13] == 750)
        // The second reader starts a second behind.
        #expect(plan.deadlines[99] == 1000)
        #expect(plan.deadlines[50] == nil)
        #expect(plan.priorities[50] == .normal)
        // Where urgent windows overlap, the sooner deadline wins.
        let overlapping = PiecePrioritizer.plan(map: map, readers: [10 << 20, 11 << 20], window: window) { _ in false }
        #expect(overlapping.deadlines[11] == 250)
        #expect(overlapping.deadlines[14] == 1750)
    }

    @Test("A file inside a larger torrent only ever asks for its own pieces")
    func fileInsideTorrent() {
        let inner = PieceMap(pieceLength: 1 << 20, fileOffset: (40 << 20) + 123, fileSize: 6 << 20)
        let start = PiecePrioritizer.plan(map: inner, readers: [], window: window) { _ in false }
        #expect(Set(start.priorities.keys) == Set(40 ... 46))
        #expect(start.deadlines.keys.allSatisfy { (40 ... 46).contains($0) })
        let playing = PiecePrioritizer.plan(map: inner, readers: [5 << 20], window: window) { _ in false }
        #expect(playing.deadlines.keys.sorted() == [45, 46])
        #expect(PiecePrioritizer.plan(map: PieceMap(pieceLength: 1 << 20, fileOffset: 0, fileSize: 0), readers: [0]) { _ in false } == PiecePlan())
    }

    @Test("For a file too large to keep, only what the player is about to need is fetched")
    func withoutBackgroundDownload() {
        let waiting = PiecePrioritizer.plan(map: map, readers: [], window: window, fetchesWholeFile: false) { _ in false }
        #expect(waiting.deadlines == [0: 0, 1: 250, 98: 250, 99: 500])
        #expect(waiting.priorities[50] == .skip)
        #expect(waiting.priorities[0] == .high)

        let playing = PiecePrioritizer.plan(map: map, readers: [20 << 20], window: window, fetchesWholeFile: false) { _ in false }
        #expect(playing.deadlines.keys.sorted() == [20, 21, 22, 23])
        #expect(playing.priorities[24] == .high && playing.priorities[33] == .high)
        #expect(playing.priorities[34] == .skip)
        #expect(playing.priorities[19] == .skip)
        #expect(playing.priorities.values.filter { $0 != .skip }.count == 14)
    }

    @Test("Only what changed between two plans is sent to the engine")
    func changes() {
        let before = PiecePrioritizer.plan(map: map, readers: [20 << 20], window: window) { _ in false }
        // The player has read one piece on, and that piece has arrived.
        let after = PiecePrioritizer.plan(map: map, readers: [21 << 20], window: window) { $0 == 20 }
        let changes = after.changes(from: before)
        #expect(changes.deadlinesToClear == [20])
        // 21…23 move a step sooner and 24 is new.
        #expect(changes.deadlinesToSet == [21: 0, 22: 250, 23: 500, 24: 750])
        // The stretch fetched ahead moves on by one piece; piece 24 was already in it.
        #expect(changes.prioritiesToSet == [34: .high])
        #expect(after.changes(from: after).isEmpty)
        // From nothing, everything is new.
        #expect(before.changes(from: PiecePlan()).deadlinesToSet == before.deadlines)
    }
}
