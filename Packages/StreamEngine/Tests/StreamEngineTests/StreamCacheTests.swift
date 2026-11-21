import Foundation
@testable import StreamEngine
import Testing

@Suite("Stream cache")
struct StreamCacheTests {
    private func entry(_ id: String, megabytes: Int64, daysAgo: Double) -> StreamCacheEntry {
        StreamCacheEntry(id: id, bytes: megabytes << 20, lastUsed: Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86400))
    }

    @Test("The least recently watched go first, until what is left fits; what is playing is never removed")
    func evictions() {
        let entries = [entry("new", megabytes: 400, daysAgo: 0), entry("old", megabytes: 300, daysAgo: 9), entry("mid", megabytes: 500, daysAgo: 3)]
        #expect(StreamCache.evictions(entries: entries, active: [], budget: 2000 << 20).isEmpty)
        #expect(StreamCache.evictions(entries: entries, active: [], budget: 1000 << 20) == ["old"])
        #expect(StreamCache.evictions(entries: entries, active: [], budget: 450 << 20) == ["old", "mid"])
        #expect(StreamCache.evictions(entries: entries, active: [], budget: 0) == ["old", "mid", "new"])
        // The oldest is playing: it stays, and the next oldest goes instead.
        #expect(StreamCache.evictions(entries: entries, active: ["old"], budget: 1000 << 20) == ["mid"])
        // Everything is playing: nothing can go, even over budget.
        #expect(StreamCache.evictions(entries: entries, active: ["old", "mid", "new"], budget: 0).isEmpty)
    }

    @Test("Files larger than the budget are not kept whole")
    func wholeFiles() {
        let cache = StreamCache(directory: URL(fileURLWithPath: "/tmp/none"), policy: StreamCachePolicy(maximumBytes: 1000))
        #expect(cache.canHoldWholeFile(ofSize: 1000))
        #expect(!cache.canHoldWholeFile(ofSize: 1001))
        #expect(StreamCachePolicy(maximumBytes: -5).maximumBytes == 0)
    }

    @Test("Measures what is on disk, marks use, trims to the budget and clears")
    func onDisk() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: directory) }
        func make(_ id: String, bytes: Int, daysAgo: Double) throws {
            let folder = directory.appendingPathComponent(id).appendingPathComponent("Sub")
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: bytes).write(to: folder.appendingPathComponent("video.mkv"))
            try files.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-daysAgo * 86400)],
                ofItemAtPath: directory.appendingPathComponent(id).path
            )
        }
        try make("aaaa", bytes: 600_000, daysAgo: 5)
        try make("bbbb", bytes: 900_000, daysAgo: 1)
        try make("cccc", bytes: 300_000, daysAgo: 10)
        try Data(count: 10).write(to: directory.appendingPathComponent("stray-file"))

        var cache = StreamCache(directory: directory, policy: StreamCachePolicy(maximumBytes: 1_600_000))
        let entries = cache.entries().sorted { $0.id < $1.id }
        #expect(entries.map(\.id) == ["aaaa", "bbbb", "cccc"])
        // Allocated sizes are whole disk blocks: at least the file's length, not much more.
        #expect(entries[0].bytes >= 600_000 && entries[0].bytes < 700_000)
        #expect(cache.totalBytes() >= 1_800_000)

        // Watching the oldest makes it the newest.
        cache.markUsed("cccc")
        #expect(cache.trim(active: []) == ["aaaa"])
        #expect(cache.entries().map(\.id).sorted() == ["bbbb", "cccc"])
        #expect(cache.trim(active: []).isEmpty)

        cache.policy = StreamCachePolicy(maximumBytes: 0)
        #expect(cache.trim(active: ["bbbb"]) == ["cccc"])
        #expect(cache.clear(active: ["bbbb"]) == 0)
        #expect(cache.clear(active: []) >= 900_000)
        #expect(cache.entries().isEmpty)
        // A cache folder that does not exist is simply empty.
        #expect(StreamCache(directory: directory.appendingPathComponent("missing")).entries().isEmpty)
    }
}

@Suite("Choosing the file to play from a torrent")
struct TorrentFileChooserTests {
    private let files = [
        TorrentFile(index: 0, path: "Show/Sample/sample.mkv", size: 20 << 20, offset: 0),
        TorrentFile(index: 1, path: "Show/Show.S01E01.mkv", size: 900 << 20, offset: 20 << 20),
        TorrentFile(index: 2, path: "Show/Show.S01E02.mkv", size: 950 << 20, offset: 920 << 20),
        TorrentFile(index: 3, path: "Show/extras.zip", size: 4000 << 20, offset: 1870 << 20),
        TorrentFile(index: 4, path: "Show/theme.flac", size: 30 << 20, offset: 5870 << 20),
    ]

    @Test("The stream's file number wins, then its file name, then the largest video")
    func choice() {
        #expect(TorrentFileChooser.choose(from: files, index: 1, name: "Show.S01E02.mkv")?.index == 1)
        #expect(TorrentFileChooser.choose(from: files, index: nil, name: "show.s01e01.MKV")?.index == 1)
        // A number the torrent does not have falls through to the name, then to the largest video.
        #expect(TorrentFileChooser.choose(from: files, index: 99, name: "Show.S01E01.mkv")?.index == 1)
        #expect(TorrentFileChooser.choose(from: files, index: nil, name: nil)?.index == 2)
        #expect(TorrentFileChooser.choose(from: files, index: nil, name: "")?.index == 2)
    }

    @Test("Without a video the largest audio file is played; with neither, nothing")
    func fallbacks() {
        let noVideo = files.filter { !$0.name.hasSuffix(".mkv") }
        #expect(TorrentFileChooser.choose(from: noVideo, index: nil, name: nil)?.index == 4)
        #expect(TorrentFileChooser.choose(from: [files[3]], index: nil, name: nil) == nil)
        #expect(TorrentFileChooser.choose(from: [], index: 0, name: "x") == nil)
    }
}

@Suite("Stream manager over a loopback swarm", .serialized)
struct StreamManagerTests {
    private func makeManager(root: URL, budget: Int64) -> StreamManager {
        StreamManager(
            settings: .loopback(),
            cache: StreamCache(directory: root.appendingPathComponent("cache"), policy: StreamCachePolicy(maximumBytes: budget))
        )
    }

    /// Opens the swarm's torrent through the manager, introducing it to the sharing engine on the way.
    private func open(_ swarm: LoopbackSwarm, in manager: StreamManager, fileName: String? = nil) async throws -> OpenedStream {
        let source = try #require(TorrentSource(infoHash: swarm.infoHash))
        let engine = try await manager.runningEngine()
        async let stream = manager.open(source, fileName: fileName, metadataTimeout: .seconds(20))
        for _ in 0 ..< 200 where await !engine.activeTorrents.contains(swarm.infoHash) {
            try await Task.sleep(for: .milliseconds(10))
        }
        var port = 0
        for _ in 0 ..< 200 where port == 0 {
            port = await swarm.seeder.listenPort
            try await Task.sleep(for: .milliseconds(10))
        }
        await engine.connect(swarm.infoHash, toPeerAt: "127.0.0.1", port: port)
        return try await stream
    }

    @Test("Opening a torrent gives a loopback address that serves its file; closing keeps the data for next time")
    func opensServesAndCloses() async throws {
        let swarm = try await LoopbackSwarm.make(size: 2 << 20, fileName: "feature.mkv")
        let manager = makeManager(root: swarm.root, budget: 100 << 20)
        defer {
            Task {
                await manager.shutdown()
                await swarm.tearDown()
            }
        }
        let stream = try await open(swarm, in: manager)
        #expect(stream.file.name == "feature.mkv" && stream.fetchesWholeFile)
        #expect(stream.url.host == "127.0.0.1" && stream.url.lastPathComponent == "feature.mkv")
        #expect(await manager.openStreams == [swarm.infoHash])
        // Asking again gives the same stream rather than a second one.
        #expect(try await manager.open(#require(TorrentSource(infoHash: swarm.infoHash))) == stream)

        let (data, response) = try await URLSession.shared.data(from: stream.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == swarm.contents)
        let status = try #require(await manager.status(of: swarm.infoHash))
        #expect(status.progress == 1)

        await manager.close(swarm.infoHash)
        #expect(await manager.openStreams.isEmpty)
        #expect(await manager.status(of: swarm.infoHash) == nil)
        // The address no longer answers, but what was fetched is still in the cache.
        let after = try? await URLSession.shared.data(from: stream.url)
        #expect((after?.1 as? HTTPURLResponse)?.statusCode == 404)
        #expect(await manager.cacheSize() >= Int64(swarm.contents.count))
    }

    @Test("A cache that is too small is cleared when the stream closes, and a file too large for it is not fetched whole")
    func smallCache() async throws {
        let swarm = try await LoopbackSwarm.make(size: 2 << 20, fileName: "feature.mkv")
        let manager = makeManager(root: swarm.root, budget: 1 << 20)
        defer {
            Task {
                await manager.shutdown()
                await swarm.tearDown()
            }
        }
        let stream = try await open(swarm, in: manager)
        #expect(!stream.fetchesWholeFile)
        // What the player asks for still arrives.
        var request = URLRequest(url: stream.url)
        request.setValue("bytes=1000000-1099999", forHTTPHeaderField: "Range")
        let (data, _) = try await URLSession.shared.data(for: request)
        #expect(data == swarm.contents.subdata(in: 1_000_000 ..< 1_100_000))
        // While it plays it is not removed, whatever the budget.
        #expect(await manager.trimCache().isEmpty)

        await manager.close(swarm.infoHash)
        // The engine lets go of the files a moment after it is told to: on a busy machine the
        // folder can still be there for an instant (this failed once in a full run for that reason).
        var size = await manager.cacheSize()
        for _ in 0 ..< 100 where size > 1 << 20 {
            try await Task.sleep(for: .milliseconds(50))
            _ = await manager.trimCache()
            size = await manager.cacheSize()
        }
        #expect(size <= 1 << 20)
    }

    @Test("A torrent with nothing playable in it, or with nobody sharing it, fails in words and leaves nothing behind")
    func failures() async throws {
        let swarm = try await LoopbackSwarm.make(size: 300_000, fileName: "notes.txt")
        let manager = makeManager(root: swarm.root, budget: 100 << 20)
        defer {
            Task {
                await manager.shutdown()
                await swarm.tearDown()
            }
        }
        await #expect(throws: TorrentError.noSuchFile) {
            try await open(swarm, in: manager)
        }
        #expect(await manager.openStreams.isEmpty)

        let lonely = try #require(TorrentSource(infoHash: String(repeating: "cd", count: 20)))
        await #expect(throws: TorrentError.metadataTimeout) {
            try await manager.open(lonely, metadataTimeout: .milliseconds(300))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await manager.cacheSize() == 0)
        #expect(TorrentError.metadataTimeout.userMessage.contains("No one sharing"))
    }
}
