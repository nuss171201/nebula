import Foundation
@testable import StreamEngine
import Testing

/// Two engines on this machine: one shares a generated file, the other fetches it.
/// Nothing leaves the loopback interface: no trackers, no hash table, no discovery.
struct LoopbackSwarm {
    let root: URL
    let file: URL
    let contents: Data
    let infoHash: String
    let seeder: TorrentEngine
    let leecher: TorrentEngine

    /// - Parameter size: Bytes of pseudo-random data to share.
    static func make(size: Int = 3 << 20, pieceLength: Int = 256 * 1024, fileName: String = "sample.bin") async throws -> LoopbackSwarm {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-\(UUID().uuidString)", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        // Deterministic noise, so every byte's position matters when comparing.
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: size)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0 ... 255, using: &generator)
        }
        let contents = Data(bytes)
        let file = shared.appendingPathComponent(fileName)
        try contents.write(to: file)

        let torrentFile = root.appendingPathComponent("sample.torrent")
        let infoHash = try TorrentCreator.makeTorrent(forFile: file, pieceLength: pieceLength, output: torrentFile)

        let seeder = TorrentEngine(settings: .loopback(), directory: root.appendingPathComponent("seeder"))
        #expect(try await seeder.seed(torrentFile: torrentFile, dataDirectory: shared) == infoHash)
        let leecher = TorrentEngine(settings: .loopback(), directory: root.appendingPathComponent("leecher"))
        return LoopbackSwarm(root: root, file: file, contents: contents, infoHash: infoHash, seeder: seeder, leecher: leecher)
    }

    /// Adds the torrent to the fetching engine and introduces it to the sharing one.
    func connect() async throws {
        let source = try #require(TorrentSource(infoHash: infoHash))
        try await leecher.add(source)
        var port = 0
        for _ in 0 ..< 200 where port == 0 {
            port = await seeder.listenPort
            if port == 0 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        #expect(port != 0)
        await leecher.connect(infoHash, toPeerAt: "127.0.0.1", port: port)
    }

    func tearDown() async {
        await leecher.shutdown()
        await seeder.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Torrent sources and engine values")
struct TorrentValueTests {
    @Test("An info hash is 40 hexadecimal characters; trackers that are not web or UDP addresses are dropped")
    func sources() throws {
        let source = try #require(TorrentSource(
            infoHash: "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
            trackers: ["udp://tracker.example.org:1337/announce", "https://t.example.org/announce", "file:///etc/passwd", "dht:abc"]
        ))
        #expect(source.infoHash == "abcdef0123456789abcdef0123456789abcdef01")
        #expect(source.trackers == ["udp://tracker.example.org:1337/announce", "https://t.example.org/announce"])
        #expect(TorrentSource(infoHash: "abc") == nil)
        #expect(TorrentSource(infoHash: String(repeating: "z", count: 40)) == nil)
    }

    @Test("Progress is the share of the wanted file that has arrived")
    func progress() {
        var status = TorrentStatus(
            hasMetadata: true, downloadRate: 0, uploadRate: 0, peers: 1, seeds: 1,
            wantedBytes: 200, wantedBytesDone: 50, isFinished: false, errorMessage: nil
        )
        #expect(status.progress == 0.25)
        status.wantedBytes = 0
        #expect(status.progress == 0)
    }
}

@Suite("Torrent engine over a loopback swarm", .serialized)
struct TorrentEngineTests {
    @Test("A torrent known only by its hash gets its description from a peer, and its bytes arrive intact wherever they are read")
    func fetchesAndReads() async throws {
        let swarm = try await LoopbackSwarm.make()
        defer { Task { await swarm.tearDown() } }
        try await swarm.connect()

        let info = try await swarm.leecher.metadata(of: swarm.infoHash, timeout: .seconds(20))
        #expect(info.files.map(\.name) == ["sample.bin"])
        #expect(info.totalSize == Int64(swarm.contents.count))
        #expect(info.pieceLength == 256 * 1024)
        #expect(info.pieceCount == 12)

        let map = try await swarm.leecher.open(file: 0, of: swarm.infoHash)
        #expect(map.fileSize == Int64(swarm.contents.count))
        let source = TorrentByteSource(engine: swarm.leecher, infoHash: swarm.infoHash, fileIndex: 0, size: map.fileSize)
        let reader = UUID()

        // From the middle of a piece near the end, as a player looking for a container's index would.
        let late = Int64(swarm.contents.count) - 300_000
        let tail = try await source.read(at: late, maxLength: 1 << 20, reader: reader)
        #expect(!tail.isEmpty)
        #expect(tail == swarm.contents.subdata(in: Int(late) ..< Int(late) + tail.count))

        // Then the whole file from the start, in the steps the reads come back in.
        var assembled = Data()
        while assembled.count < swarm.contents.count {
            let chunk = try await source.read(at: Int64(assembled.count), maxLength: 100_000, reader: reader)
            #expect(!chunk.isEmpty && chunk.count <= 100_000)
            assembled.append(chunk)
        }
        #expect(assembled == swarm.contents)
        // Past the end there is nothing.
        #expect(try await source.read(at: Int64(swarm.contents.count), maxLength: 10, reader: reader).isEmpty)
        await source.close(reader: reader)

        let status = try #require(await swarm.leecher.status(of: swarm.infoHash))
        #expect(status.hasMetadata && status.progress == 1)
        // The data is where the cache will look for it.
        let stored = swarm.leecher.dataDirectory(for: swarm.infoHash).appendingPathComponent("sample.bin")
        #expect(FileManager.default.fileExists(atPath: stored.path))
    }

    /// How far beyond the next piece in file order the arrivals ran, at the worst, counting
    /// from `start` and leaving out `ignored` (the file's last pieces, which are asked for
    /// before the player has said where it reads).
    private func worstLead(of arrivals: [Int], from start: Int, ignoring ignored: Range<Int>) -> Int {
        var have = Set<Int>()
        var next = start
        var worst = 0
        for piece in arrivals where piece >= start && !ignored.contains(piece) {
            have.insert(piece)
            while have.contains(next) {
                next += 1
            }
            worst = max(worst, piece - next)
        }
        return worst
    }

    @Test("Pieces arrive in the order they are played in, whatever their size", arguments: [256 * 1024, 4 << 20])
    func arrivesInPlayingOrder(pieceLength: Int) async throws {
        let size = 40 << 20
        let swarm = try await LoopbackSwarm.make(size: size, pieceLength: pieceLength)
        defer { Task { await swarm.tearDown() } }
        try await swarm.connect()
        _ = try await swarm.leecher.metadata(of: swarm.infoHash, timeout: .seconds(20))
        _ = try await swarm.leecher.open(file: 0, of: swarm.infoHash)

        let reader = UUID()
        var offset = 0
        while offset < 16 << 20 {
            offset += try await swarm.leecher.read(file: 0, of: swarm.infoHash, at: Int64(offset), maxLength: 1 << 20, reader: reader).count
        }
        let arrivals = await swarm.leecher.arrivalOrder(of: swarm.infoHash)
        let pieceCount = size / pieceLength
        let tail = pieceCount - max((2 << 20) / pieceLength, 1) ..< pieceCount
        // Before this was put right the arrivals were in no order at all: the file choice,
        // taking effect a moment after the plan, set every piece back to the same priority,
        // and between seeds "rarest first" is at random (a lead of 300 pieces was measured).
        // What is left is the megabyte being waited for, which comes in any order.
        #expect(arrivals.count >= (16 << 20) / pieceLength)
        #expect(worstLead(of: arrivals, from: 0, ignoring: tail) <= max((1 << 20) / pieceLength, 1))
    }

    @Test("After a jump ahead the download carries on from there, and what was skipped waits until the rest is in")
    func carriesOnFromAJump() async throws {
        let pieceLength = 256 * 1024
        let size = 24 << 20
        let swarm = try await LoopbackSwarm.make(size: size, pieceLength: pieceLength)
        defer { Task { await swarm.tearDown() } }
        try await swarm.connect()
        _ = try await swarm.leecher.metadata(of: swarm.infoHash, timeout: .seconds(20))
        _ = try await swarm.leecher.open(file: 0, of: swarm.infoHash)

        // Straight to the middle, as when a film is resumed, and on to the end.
        let reader = UUID()
        let jump = 12 << 20
        var offset = jump
        while offset < size {
            offset += try await swarm.leecher.read(file: 0, of: swarm.infoHash, at: Int64(offset), maxLength: 1 << 20, reader: reader).count
        }
        await swarm.leecher.close(reader: reader, file: 0, of: swarm.infoHash)
        // With nothing left ahead, the first half follows.
        for _ in 0 ..< 400 where await swarm.leecher.status(of: swarm.infoHash)?.progress != 1 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await swarm.leecher.status(of: swarm.infoHash)?.progress == 1)

        let arrivals = await swarm.leecher.arrivalOrder(of: swarm.infoHash)
        let jumpPiece = jump / pieceLength
        // The file's first two megabytes are asked for before the player says where it reads.
        let skipped = (2 << 20) / pieceLength ..< jumpPiece
        let lastAhead = try #require(arrivals.lastIndex { $0 >= jumpPiece })
        let firstSkipped = try #require(arrivals.firstIndex { skipped.contains($0) })
        #expect(firstSkipped > lastAhead)
        // The file's last two megabytes are asked for at the same moment, and one of those
        // pieces can be on its way before the reader has said where it starts: it says nothing
        // about the order of what follows the jump. (Not allowing for it made this fail on a
        // busy machine, three times in some twenty full runs.)
        let pieceCount = size / pieceLength
        let tail = pieceCount - (2 << 20) / pieceLength ..< pieceCount
        #expect(worstLead(of: arrivals, from: jumpPiece, ignoring: tail) <= 4)
    }

    @Test("With nobody to ask, waiting for the description gives up after the timeout")
    func metadataTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lonely-\(UUID().uuidString)")
        let engine = TorrentEngine(settings: .loopback(), directory: directory)
        defer {
            Task {
                await engine.shutdown()
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let source = try #require(TorrentSource(infoHash: String(repeating: "ab", count: 20)))
        try await engine.add(source)
        // Adding it twice is harmless.
        try await engine.add(source)
        #expect(await engine.activeTorrents == [source.infoHash])
        await #expect(throws: TorrentError.metadataTimeout) {
            try await engine.metadata(of: source.infoHash, timeout: .milliseconds(300))
        }
    }

    @Test("Removing a torrent fails whatever was waiting on it, and can delete its data")
    func removal() async throws {
        let swarm = try await LoopbackSwarm.make(size: 1 << 20)
        defer { Task { await swarm.tearDown() } }
        // Not connected to the sharing engine: the description never arrives.
        try await swarm.leecher.add(#require(TorrentSource(infoHash: swarm.infoHash)))
        let waiting = Task { try await swarm.leecher.metadata(of: swarm.infoHash, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        await swarm.leecher.remove(swarm.infoHash, deletingData: true)
        await #expect(throws: TorrentError.removed) {
            try await waiting.value
        }
        #expect(await swarm.leecher.status(of: swarm.infoHash) == nil)
        await #expect(throws: TorrentError.removed) {
            try await swarm.leecher.metadata(of: swarm.infoHash)
        }
    }

    @Test("A reader that is cancelled while waiting for a piece stops waiting")
    func cancellation() async throws {
        let swarm = try await LoopbackSwarm.make(size: 1 << 20)
        defer { Task { await swarm.tearDown() } }
        try await swarm.connect()
        _ = try await swarm.leecher.metadata(of: swarm.infoHash, timeout: .seconds(20))
        _ = try await swarm.leecher.open(file: 0, of: swarm.infoHash)
        // A file number the torrent does not have.
        await #expect(throws: TorrentError.noSuchFile) {
            try await swarm.leecher.open(file: 7, of: swarm.infoHash)
        }
        // Cut the supply, then ask for something: the read can only wait.
        await swarm.seeder.shutdown()
        await swarm.leecher.remove(swarm.infoHash, deletingData: true)
        try await swarm.leecher.add(#require(TorrentSource(infoHash: swarm.infoHash)))
        let reading = Task { try await swarm.leecher.metadata(of: swarm.infoHash, timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        reading.cancel()
        await #expect(throws: CancellationError.self) {
            try await reading.value
        }
    }
}
