import Foundation
@testable import StreamEngine
import Testing

@Suite("What the player waits for, as a share that has arrived")
struct ArrivalTests {
    @Test("The pieces fetched before anything is asked for are both ends of the file")
    func edgePieces() {
        // A film with 4 MiB pieces: two megabytes at each end are one piece each.
        let film = PieceMap(pieceLength: 4 << 20, fileOffset: 0, fileSize: 100 << 20)
        #expect(PiecePrioritizer.edgePieces(map: film) == [0, 24])
        // Small pieces: eight at the start, eight at the end.
        let small = PieceMap(pieceLength: 256 << 10, fileOffset: 0, fileSize: 10 << 20)
        #expect(PiecePrioritizer.edgePieces(map: small) == Set(0 ... 7).union(32 ... 39))
        // A file shorter than one edge is its own start and end.
        let tiny = PieceMap(pieceLength: 256 << 10, fileOffset: 0, fileSize: 300 << 10)
        #expect(PiecePrioritizer.edgePieces(map: tiny) == [0, 1])
        #expect(PiecePrioritizer.edgePieces(map: PieceMap(pieceLength: 1024, fileOffset: 0, fileSize: 0)).isEmpty)
        // A file in the middle of a torrent starts where it starts.
        let second = PieceMap(pieceLength: 4 << 20, fileOffset: 40 << 20, fileSize: 40 << 20)
        #expect(PiecePrioritizer.edgePieces(map: second) == [10, 19])
    }

    @Test("Progress is what has arrived of what is wanted, and never outside 0 to 1")
    func fraction() {
        #expect(ArrivalProgress(bytesDone: 0, bytesWanted: 0).fraction == 0)
        #expect(ArrivalProgress(bytesDone: 1, bytesWanted: 4).fraction == 0.25)
        #expect(ArrivalProgress(bytesDone: 9, bytesWanted: 4).fraction == 1)
        #expect(ArrivalProgress(bytesDone: 1, bytesWanted: 4).bytesLeft == 3)
        #expect(ArrivalProgress(bytesDone: 9, bytesWanted: 4).bytesLeft == 0)
    }

    @Test("A file that has just been opened waits for both of its ends; a later wait counts only what it waits for")
    func countsWhatIsWaitedFor() async throws {
        let swarm = try await LoopbackSwarm.make(size: 6 << 20, pieceLength: 1 << 20)
        defer { Task { await swarm.tearDown() } }
        let source = try #require(TorrentSource(infoHash: swarm.infoHash))
        // Nobody to fetch from yet, so the first reading is of nothing having arrived.
        try await swarm.leecher.add(source)
        var port = 0
        for _ in 0 ..< 200 where port == 0 {
            port = await swarm.seeder.listenPort
            try await Task.sleep(for: .milliseconds(25))
        }
        // The description has to come from the seeder; then the torrent is cut off from it again.
        await swarm.leecher.connect(swarm.infoHash, toPeerAt: "127.0.0.1", port: port)
        _ = try await swarm.leecher.metadata(of: swarm.infoHash, timeout: .seconds(20))
        _ = try await swarm.leecher.open(file: 0, of: swarm.infoHash)

        // Two megabytes at each end, in pieces of one: four megabytes are waited for.
        let first = try #require(await swarm.leecher.arrival(of: swarm.infoHash))
        #expect(first.bytesWanted == 4 << 20)

        var last = first
        for _ in 0 ..< 400 where last.fraction < 1 {
            try await Task.sleep(for: .milliseconds(25))
            let next = try #require(await swarm.leecher.arrival(of: swarm.infoHash))
            // The same four megabytes throughout, and never fewer of them than before.
            #expect(next.bytesWanted == first.bytesWanted && next.bytesDone >= last.bytesDone)
            last = next
        }
        #expect(last.fraction == 1 && last.bytesLeft == 0)

        // The player plays, then stalls again: what it waited for before no longer counts.
        await swarm.leecher.restartArrival(of: swarm.infoHash)
        #expect(await swarm.leecher.arrival(of: swarm.infoHash) == nil)
        #expect(await swarm.leecher.arrival(of: "0000000000000000000000000000000000000000") == nil)
    }
}

@Suite("Keeping a file: downloads through the stream manager", .serialized)
struct DownloadManagerTests {
    private func makeManager(root: URL) -> StreamManager {
        StreamManager(settings: .loopback(), cache: StreamCache(directory: root.appendingPathComponent("cache")))
    }

    private func request(for swarm: LoopbackSwarm) throws -> DownloadRequest {
        try DownloadRequest(
            source: #require(TorrentSource(infoHash: swarm.infoHash)),
            directory: swarm.root.appendingPathComponent("downloads/.incomplete/\(swarm.infoHash)", isDirectory: true)
        )
    }

    /// Introduces the manager's engine to the one that shares the file, as a tracker would.
    private func introduce(_ manager: StreamManager, to swarm: LoopbackSwarm) async throws {
        for _ in 0 ..< 400 where await !manager.isFetching(swarm.infoHash) {
            try await Task.sleep(for: .milliseconds(10))
        }
        var port = 0
        for _ in 0 ..< 200 where port == 0 {
            port = await swarm.seeder.listenPort
            try await Task.sleep(for: .milliseconds(10))
        }
        await manager.connect(swarm.infoHash, toPeerAt: "127.0.0.1", port: port)
    }

    private func phase(of manager: StreamManager, becomes wanted: DownloadReading.Phase, within timeout: Duration = .seconds(30)) async -> DownloadReading? {
        let deadline = ContinuousClock.now + timeout
        var reading = await manager.downloadReading()
        while reading?.phase != wanted, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
            reading = await manager.downloadReading()
        }
        return reading
    }

    @Test("A download fetches the whole file into its own folder, outside the cache, and lets go of it when asked")
    func downloadsWholeFile() async throws {
        let swarm = try await LoopbackSwarm.make(size: 3 << 20, fileName: "feature.mkv")
        let manager = makeManager(root: swarm.root)
        defer {
            Task {
                await manager.shutdown()
                await swarm.tearDown()
            }
        }
        #expect(await manager.downloadReading() == nil)
        let request = try request(for: swarm)
        await manager.startDownload(request)
        #expect(await manager.downloadReading()?.phase == .findingPeers)
        // Not finished, and not to be let go of, while it is still on its way.
        #expect(await !manager.releaseFinishedDownload())
        try await introduce(manager, to: swarm)

        let reading = try #require(await phase(of: manager, becomes: .finished))
        #expect(reading.phase == .finished && reading.file?.name == "feature.mkv")
        let file = try #require(reading.fileURL)
        #expect(file.path.hasPrefix(request.directory.path))
        #expect(try Data(contentsOf: file) == swarm.contents)
        // Nothing of it is in the cache, so clearing the cache cannot take it.
        #expect(await manager.cacheSize() == 0)

        #expect(await manager.releaseFinishedDownload())
        #expect(await manager.downloadReading() == nil)
        #expect(await !manager.isFetching(swarm.infoHash))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A download gives way to a stream, and carries on from what the stream fetched once the player closes")
    func givesWayToAStream() async throws {
        let swarm = try await LoopbackSwarm.make(size: 3 << 20, fileName: "feature.mkv")
        let manager = makeManager(root: swarm.root)
        defer {
            Task {
                await manager.shutdown()
                await swarm.tearDown()
            }
        }
        let request = try request(for: swarm)
        await manager.startDownload(request)
        #expect(await manager.downloadReading()?.phase == .findingPeers)

        // The same film is played before the download has found anyone.
        async let opening = manager.open(request.source, metadataTimeout: .seconds(20))
        #expect(await phase(of: manager, becomes: .waitingForPlayer)?.phase == .waitingForPlayer)
        try await introduce(manager, to: swarm)
        let stream = try await opening
        #expect(stream.file.name == "feature.mkv")
        // The stream is the cache's; the download has nothing yet and is not running.
        #expect(await manager.downloadReading()?.phase == .waitingForPlayer)
        #expect(!FileManager.default.fileExists(atPath: request.directory.appendingPathComponent("feature.mkv").path))
        let (played, _) = try await URLSession.shared.data(from: stream.url)
        #expect(played == swarm.contents)

        await manager.close(swarm.infoHash)
        // The download starts again, with what the stream fetched as its own.
        #expect(await phase(of: manager, becomes: .findingPeers)?.phase != .waitingForPlayer)
        try await introduce(manager, to: swarm)
        let reading = try #require(await phase(of: manager, becomes: .finished))
        #expect(try Data(contentsOf: #require(reading.fileURL)) == swarm.contents)
        #expect(!FileManager.default.fileExists(atPath: swarm.root.appendingPathComponent("cache/\(swarm.infoHash)").path))
    }

    @Test("The file being downloaded can be played from the download itself, which is not let go of while it plays")
    func playsFromTheDownload() async throws {
        let swarm = try await LoopbackSwarm.make(size: 3 << 20, fileName: "feature.mkv")
        let manager = makeManager(root: swarm.root)
        defer {
            Task {
                await manager.shutdown()
                await swarm.tearDown()
            }
        }
        let request = try request(for: swarm)
        await manager.startDownload(request)
        try await introduce(manager, to: swarm)
        #expect(await phase(of: manager, becomes: .finished)?.phase == .finished)

        let stream = try await manager.open(request.source, metadataTimeout: .seconds(20))
        let (played, _) = try await URLSession.shared.data(from: stream.url)
        #expect(played == swarm.contents)
        // Served from the download's folder: the cache was not involved.
        #expect(await manager.cacheSize() == 0)
        // Moving the file now would take it from under the film.
        #expect(await !manager.releaseFinishedDownload())
        await manager.close(swarm.infoHash)
        #expect(await manager.releaseFinishedDownload())
    }

    @Test("Stopping a download keeps what has arrived, or deletes it when asked; a torrent nobody shares fails with a reason")
    func stopsAndFails() async throws {
        let swarm = try await LoopbackSwarm.make(size: 2 << 20, fileName: "feature.mkv")
        let manager = makeManager(root: swarm.root)
        defer {
            Task {
                await manager.shutdown()
                await swarm.tearDown()
            }
        }
        let request = try request(for: swarm)
        await manager.startDownload(request)
        try await introduce(manager, to: swarm)
        #expect(await phase(of: manager, becomes: .finished)?.phase == .finished)
        await manager.stopDownload(deletingData: false)
        #expect(await manager.downloadReading() == nil)
        #expect(FileManager.default.fileExists(atPath: request.directory.appendingPathComponent("feature.mkv").path))

        // Started again, it finds its data and has nothing left to fetch.
        await manager.startDownload(request)
        try await introduce(manager, to: swarm)
        #expect(await phase(of: manager, becomes: .finished)?.phase == .finished)
        await manager.stopDownload(deletingData: true)
        #expect(!FileManager.default.fileExists(atPath: request.directory.path))
    }
}

@Suite("A slow arrival")
struct SlowArrivalTests {
    @Test("While a piece is on its way, the part of it that has come counts: the share grows between pieces, not only at them")
    func partialPiecesCount() async throws {
        let swarm = try await LoopbackSwarm.make(size: 4 << 20, pieceLength: 1 << 20)
        defer { Task { await swarm.tearDown() } }
        // A megabyte a second, so that each piece takes about a second to come.
        var settings = TorrentEngineSettings.loopback()
        settings.downloadRateLimit = 1 << 20
        settings.limitsPeersOnThisMachine = true
        let slow = TorrentEngine(settings: settings, directory: swarm.root.appendingPathComponent("slow"))
        defer { Task { await slow.shutdown() } }
        try await slow.add(#require(TorrentSource(infoHash: swarm.infoHash)))
        var port = 0
        for _ in 0 ..< 200 where port == 0 {
            port = await swarm.seeder.listenPort
            try await Task.sleep(for: .milliseconds(25))
        }
        await slow.connect(swarm.infoHash, toPeerAt: "127.0.0.1", port: port)
        _ = try await slow.metadata(of: swarm.infoHash, timeout: .seconds(20))
        _ = try await slow.open(file: 0, of: swarm.infoHash)

        var readings: [ArrivalProgress] = []
        let started = ContinuousClock.now
        while ContinuousClock.now - started < .seconds(30) {
            guard let reading = await slow.arrival(of: swarm.infoHash) else { break }
            readings.append(reading)
            if reading.fraction >= 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("slow-arrival-readings=\(readings.map(\.bytesDone))")
        #expect(readings.last?.fraction == 1)
        // Never backward.
        #expect(zip(readings, readings.dropFirst()).allSatisfy { $0.bytesDone <= $1.bytesDone })
        // Seen part-way through a piece at least a few times: not a count of whole pieces.
        #expect(readings.count { $0.bytesDone % (1 << 20) != 0 } >= 3)
    }
}

/// Not a test: someone on this machine sharing a file, slowly, for checking the app by hand
/// (`SEED_FILE=<path> SEED_INFO=<file> swift test --filter ManualSeed`). It writes the torrent's
/// hash and its port to SEED_INFO; the port goes to the app as `-peer 127.0.0.1:<port>`, the
/// hash to Scripts/serve-test-addon.py.
@Suite("A seeder for checks by hand")
struct ManualSeed {
    @Test(
        "Shares SEED_FILE on the loopback interface for SEED_SECONDS, at SEED_RATE bytes a second",
        .enabled(if: ProcessInfo.processInfo.environment["SEED_FILE"] != nil, "set SEED_FILE to a file to share")
    )
    func seed() async throws {
        let environment = ProcessInfo.processInfo.environment
        let file = try URL(fileURLWithPath: #require(environment["SEED_FILE"]))
        let seconds = environment["SEED_SECONDS"].flatMap(Int.init) ?? 180
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seed-\(UUID().uuidString)", isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A copy, so that the torrent's folder holds nothing else (and is not in Documents).
        let copy = shared.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        // Pieces the size films usually have: the percentage is about waiting for one of these.
        let pieceLength = environment["SEED_PIECE"].flatMap(Int.init) ?? 4 << 20
        let torrent = root.appendingPathComponent("seed.torrent")
        let infoHash = try TorrentCreator.makeTorrent(forFile: copy, pieceLength: pieceLength, output: torrent)

        var settings = TorrentEngineSettings.loopback()
        settings.uploadRateLimit = environment["SEED_RATE"].flatMap(Int.init) ?? 0
        settings.limitsPeersOnThisMachine = true
        let seeder = TorrentEngine(settings: settings, directory: root.appendingPathComponent("seeder"))
        #expect(try await seeder.seed(torrentFile: torrent, dataDirectory: shared) == infoHash)
        var port = 0
        for _ in 0 ..< 200 where port == 0 {
            port = await seeder.listenPort
            try await Task.sleep(for: .milliseconds(25))
        }
        print("seed-hash=\(infoHash) seed-port=\(port)")
        // The test runner holds a test's output back until it ends, so the same line goes to a
        // file for whoever is waiting to start the app.
        if let path = environment["SEED_INFO"] {
            try "\(infoHash) \(port)\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        try await Task.sleep(for: .seconds(seconds))
        await seeder.shutdown()
    }
}
