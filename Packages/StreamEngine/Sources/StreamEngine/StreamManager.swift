import Foundation
import MediaCore

/// Picks the file to play out of a torrent.
public enum TorrentFileChooser {
    /// The file the stream points to by number; else the one it names; else the largest
    /// video (a torrent's main feature is its biggest file). `nil` if nothing playable is there.
    public static func choose(from files: [TorrentFile], index: Int?, name: String?) -> TorrentFile? {
        if let index, let file = files.first(where: { $0.index == index }) {
            return file
        }
        if let name, !name.isEmpty, let file = files.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return file
        }
        func isKind(_ file: TorrentFile, _ extensions: Set<String>) -> Bool {
            extensions.contains((file.name as NSString).pathExtension.lowercased())
        }
        return files.filter { isKind($0, MediaFileExtensions.video) }.max { $0.size < $1.size }
            ?? files.filter { isKind($0, MediaFileExtensions.audio) }.max { $0.size < $1.size }
    }
}

/// A torrent's file that is being served to the player.
public struct OpenedStream: Sendable, Equatable {
    public let infoHash: String
    public let file: TorrentFile
    /// The loopback address the player opens.
    public let url: URL
    /// Whether the whole file is being fetched, or only what is about to be played.
    public let fetchesWholeFile: Bool
}

/// Everything behind "play this torrent": the engine, the loopback server and the cache,
/// started when first needed.
public actor StreamManager {
    private let settings: TorrentEngineSettings
    private let logSubsystem: String
    public private(set) var cache: StreamCache
    private var engine: TorrentEngine?
    private var server: StreamServer?
    private var opened: [String: OpenedStream] = [:]

    public init(settings: TorrentEngineSettings, cache: StreamCache, logSubsystem: String = "stream.engine") {
        self.settings = settings
        self.cache = cache
        self.logSubsystem = logSubsystem
    }

    /// Finds the torrent, picks its file and returns an address the player can open at once;
    /// the bytes follow as they arrive. Opening the same torrent again returns the same stream.
    /// - Parameters:
    ///   - fileIndex: The file's number in the torrent, if the stream says.
    ///   - fileName: The file's name, if the stream says.
    ///   - metadataTimeout: How long to look for someone sharing the torrent.
    public func open(
        _ source: TorrentSource,
        fileIndex: Int? = nil,
        fileName: String? = nil,
        metadataTimeout: Duration = .seconds(60)
    ) async throws -> OpenedStream {
        if let existing = opened[source.infoHash] {
            return existing
        }
        let engine = try startEngine()
        let server = try await startServer()
        try await engine.add(source)
        do {
            let info = try await engine.metadata(of: source.infoHash, timeout: metadataTimeout)
            guard let file = TorrentFileChooser.choose(from: info.files, index: fileIndex, name: fileName) else {
                throw TorrentError.noSuchFile
            }
            let fetchesWholeFile = cache.canHoldWholeFile(ofSize: file.size)
            let map = try await engine.open(file: file.index, of: source.infoHash, fetchesWholeFile: fetchesWholeFile)
            let byteSource = TorrentByteSource(engine: engine, infoHash: source.infoHash, fileIndex: file.index, size: map.fileSize)
            let url = try await server.publish(byteSource, named: file.name)
            let stream = OpenedStream(infoHash: source.infoHash, file: file, url: url, fetchesWholeFile: fetchesWholeFile)
            opened[source.infoHash] = stream
            cache.markUsed(source.infoHash)
            return stream
        } catch {
            // Nothing is left behind for a torrent that never got going.
            await engine.remove(source.infoHash, deletingData: opened[source.infoHash] == nil)
            throw error
        }
    }

    /// Tells a torrent that is open, or being opened, about a peer directly, instead of waiting
    /// for it to be discovered. Does nothing if the torrent is not there (yet).
    public func connect(_ infoHash: String, toPeerAt address: String, port: Int) async {
        await engine?.connect(infoHash, toPeerAt: address, port: port)
    }

    /// Whether the engine has been told about a torrent, open or still being found.
    public func isFetching(_ infoHash: String) async -> Bool {
        await engine?.activeTorrents.contains(infoHash) ?? false
    }

    /// How a stream is doing: speed, peers, how much has arrived.
    public func status(of infoHash: String) async -> TorrentStatus? {
        await engine?.status(of: infoHash)
    }

    /// Stops a stream. Its data stays in the cache until the cache needs the room.
    public func close(_ infoHash: String) async {
        guard let stream = opened.removeValue(forKey: infoHash) else { return }
        await server?.withdraw(stream.url)
        await engine?.remove(infoHash, deletingData: false)
        cache.markUsed(infoHash)
        trimCache()
    }

    /// Clears least recently watched data until the cache fits its budget. Returns what was removed.
    @discardableResult
    public func trimCache() -> [String] {
        cache.trim(active: Set(opened.keys))
    }

    /// Deletes everything that is not playing. Returns the bytes freed.
    @discardableResult
    public func clearCache() -> Int64 {
        cache.clear(active: Set(opened.keys))
    }

    public func setCachePolicy(_ policy: StreamCachePolicy) {
        cache.policy = policy
        trimCache()
    }

    /// Bytes the cache occupies on disk.
    public func cacheSize() -> Int64 {
        cache.totalBytes()
    }

    /// Info hashes of the streams that are open.
    public var openStreams: Set<String> {
        Set(opened.keys)
    }

    /// Stops everything. The manager starts again from scratch if used afterwards.
    public func shutdown() async {
        await server?.stop()
        await engine?.shutdown()
        server = nil
        engine = nil
        opened = [:]
    }

    /// The engine, for telling a torrent about a peer in tests.
    func runningEngine() throws -> TorrentEngine {
        try startEngine()
    }

    private func startEngine() throws -> TorrentEngine {
        if let engine {
            return engine
        }
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        let engine = TorrentEngine(settings: settings, directory: cache.directory, logSubsystem: logSubsystem)
        self.engine = engine
        return engine
    }

    private func startServer() async throws -> StreamServer {
        if let server {
            return server
        }
        let server = StreamServer(logSubsystem: logSubsystem)
        try await server.start()
        self.server = server
        return server
    }
}
