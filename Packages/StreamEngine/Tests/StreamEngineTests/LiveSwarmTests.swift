import Foundation
@testable import StreamEngine
import Testing

/// An opt-in measurement on the real network: how long the engine takes to find people sharing
/// a torrent, and how fast a file then arrives when read from its start as a player would.
/// Skipped unless a torrent is named, so CI never leaves this machine. Only ever point it at
/// something that is free to share (a Linux disc image, say):
///
///     LIVE_TORRENT_HASH=<40 hex characters> swift test --filter LiveSwarmTests
///
/// Optional: `LIVE_TORRENT_TRACKERS` (comma-separated addresses; none means the hash table
/// alone, which is all most streams come with), `LIVE_TORRENT_MEGABYTES` (how much to read,
/// 48 unless given), `LIVE_TORRENT_SECONDS` (when to give up, 120 unless given).
///
/// Local discovery and port mapping are off, so macOS has no reason to ask about the local network.
@Suite("Live swarm", .enabled(if: ProcessInfo.processInfo.environment["LIVE_TORRENT_HASH"] != nil))
struct LiveSwarmTests {
    private static func say(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    @Test("A real torrent is found and read from the start")
    func streamsFromTheStart() async throws {
        let environment = ProcessInfo.processInfo.environment
        let trackers = (environment["LIVE_TORRENT_TRACKERS"] ?? "").split(separator: ",").map(String.init)
        let source = try #require(TorrentSource(infoHash: environment["LIVE_TORRENT_HASH"] ?? "", trackers: trackers))
        let wanted = Int64(environment["LIVE_TORRENT_MEGABYTES"].flatMap(Int.init) ?? 48) * 1_000_000
        let limit = Double(environment["LIVE_TORRENT_SECONDS"].flatMap(Int.init) ?? 120)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-swarm-\(UUID().uuidString)", isDirectory: true)
        var settings = TorrentEngineSettings(userAgent: "StreamEngineTests/1.0", usesLocalDiscovery: false, mapsPorts: false)
        settings.diagnosticLevel = environment["LIVE_TORRENT_LOG"].flatMap(Int.init) ?? 0
        // No more is fetched than is read, give or take this much: the measurement is of how a
        // stream starts, and what it takes from the people sharing should be little.
        settings.window.readAheadBytes = 16 << 20
        let engine = TorrentEngine(settings: settings, directory: directory)
        await engine.setDiagnosticHandler { Self.say("      " + $0) }

        // Whatever happens, what was fetched is deleted before the test returns. (Left to a
        // task in a `defer`, it was still on disk when the process exited: 326 MB over three runs.)
        let outcome: Result<Int64, any Error>
        do {
            outcome = try await .success(Self.measure(engine, source: source, wanted: wanted, limit: limit))
        } catch {
            outcome = .failure(error)
        }
        await engine.shutdown()
        try? FileManager.default.removeItem(at: directory)
        #expect(try outcome.get() > 0)
    }

    /// Reads the torrent's largest file from its start, saying how it goes. Returns the bytes read.
    private static func measure(_ engine: TorrentEngine, source: TorrentSource, wanted: Int64, limit: Double) async throws -> Int64 {
        let clock = ContinuousClock()
        let start = clock.now
        func elapsed() -> Double {
            let duration = clock.now - start
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }

        try await engine.add(source)
        let progress = ReadProgress()
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let status = await engine.status(of: source.infoHash) else { continue }
                let rate = megabytes(Int64(status.downloadRate))
                let read = await megabytes(progress.bytes)
                say(String(format: "%5.0f s  ", elapsed()) + "peers \(status.peers) (seeds \(status.seeds))  \(rate)/s  read \(read)")
            }
        }
        defer { watcher.cancel() }

        let info = try await engine.metadata(of: source.infoHash, timeout: .seconds(limit))
        say(String(format: "description after %.1f s: ", elapsed()) + "\(info.name), pieces of \(info.pieceLength / 1024) KiB")
        let file = try #require(info.files.max { $0.size < $1.size })
        let map = try await engine.open(file: file.index, of: source.infoHash, fetchesWholeFile: false)
        let reader = UUID()
        var offset: Int64 = 0
        var firstByte: Double?
        while offset < min(wanted, map.fileSize), elapsed() < limit {
            let chunk = try await engine.read(file: file.index, of: source.infoHash, at: offset, maxLength: 1 << 20, reader: reader)
            if firstByte == nil {
                firstByte = elapsed()
                say(String(format: "first bytes after %.1f s", elapsed()))
            }
            offset += Int64(chunk.count)
            await progress.set(offset)
        }
        await engine.close(reader: reader, file: file.index, of: source.infoHash)
        let seconds = elapsed()
        say(String(format: "read \(megabytes(offset)) in %.1f s", seconds))
        if let firstByte, seconds > firstByte {
            say("that is \(megabytes(Int64(Double(offset) / (seconds - firstByte))))/s once it had started")
        }
        return offset
    }
}

/// How far the reading has got, for the line printed every two seconds.
private actor ReadProgress {
    private(set) var bytes: Int64 = 0

    func set(_ value: Int64) {
        bytes = value
    }
}
