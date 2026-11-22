import Foundation
import os
import TorrentBridge

/// What the bridge reports, as values that can cross to the engine's actor in order.
enum TorrentEvent: Sendable {
    case metadata(String)
    case pieceFinished(String, Int)
    case pieceRead(String, Int, Data?, String?)
    case failed(String, String)
    case fileChoiceApplied(String)
    case log(String)
}

/// Receives the bridge's callbacks (on its private queue) and forwards them as a stream.
private final class EventRelay: NSObject, TBSessionDelegate, Sendable {
    private let continuation: AsyncStream<TorrentEvent>.Continuation

    init(continuation: AsyncStream<TorrentEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Ends the stream, and with it the task that reads it.
    func finish() {
        continuation.finish()
    }

    func torrentDidReceiveMetadata(_ infoHash: String) {
        continuation.yield(.metadata(infoHash))
    }

    func torrent(_ infoHash: String, didFinishPiece piece: Int) {
        continuation.yield(.pieceFinished(infoHash, piece))
    }

    func torrent(_ infoHash: String, didReadPiece piece: Int, data: Data?, error message: String?) {
        continuation.yield(.pieceRead(infoHash, piece, data, message))
    }

    func torrent(_ infoHash: String, didFailWithMessage message: String) {
        continuation.yield(.failed(infoHash, message))
    }

    func torrentDidApplyFileChoice(_ infoHash: String) {
        continuation.yield(.fileChoiceApplied(infoHash))
    }

    func sessionDidLog(_ line: String) {
        continuation.yield(.log(line))
    }
}

/// Downloads torrents for playing: fetches the pieces around where the player is reading
/// first, and hands out the bytes of a file as they arrive.
///
/// One engine is one libtorrent session. Torrents are named by their info hash.
public actor TorrentEngine {
    /// Bytes of recently read pieces kept per torrent, so that a player reading a piece in
    /// several steps does not have it fetched from disk each time.
    static let pieceCacheBytes = 32 << 20

    struct Waiter<Value: Sendable> {
        let id: UUID
        let continuation: CheckedContinuation<Value, any Error>
    }

    struct Reader {
        var offset: Int64
        /// Larger is more recent.
        var lastActive: Int
    }

    struct FileStream {
        var map: PieceMap
        var fetchesWholeFile = true
        var readers: [UUID: Reader] = [:]
        var plan = PiecePlan()
        /// The piece each reader was last planned for; a new plan is only made when one moves on.
        var plannedPieces: [UUID: Int] = [:]
        /// What the player is held up by: the pieces the file was opened with, and each one a
        /// reader has waited for since (`arrival(of:)`).
        var awaited: Set<Int> = []
    }

    struct Torrent {
        var info: TorrentInfo?
        var failure: String?
        var completed: Set<Int> = []
        var streams: [Int: FileStream] = [:]
        var metadataWaiters: [Waiter<TorrentInfo>] = []
        var pieceWaiters: [Int: [Waiter<Void>]] = [:]
        var readWaiters: [Int: [Waiter<Data>]] = [:]
        var cachedPieces: [(piece: Int, data: Data)] = []
        /// Pieces in the order they arrived, most recent last (the last few hundred).
        var arrivals: [Int] = []
        /// When a reader started waiting for each piece that is being waited for.
        var waitingSince: [Int: ContinuousClock.Instant] = [:]
        /// When the torrent was added, for saying how long things took.
        var addedAt = ContinuousClock.now
    }

    public let directory: URL
    private let window: StreamingWindow
    let session: TBSession
    private let relay: EventRelay
    let logger: Logger
    var torrents: [String: Torrent] = [:]
    private var activity = 0
    var isShutDown = false
    /// Looks in on what is being waited for (`TorrentEngine+Watch`).
    var watchTask: Task<Void, Never>?
    /// Where diagnostic lines go besides the log. For the live measurement.
    var onDiagnostic: (@Sendable (String) -> Void)?

    func setDiagnosticHandler(_ handler: (@Sendable (String) -> Void)?) {
        onDiagnostic = handler
    }

    /// - Parameter directory: Where torrents keep their data, one folder per torrent.
    public init(settings: TorrentEngineSettings, directory: URL, logSubsystem: String = "stream.engine") {
        self.directory = directory
        window = settings.window
        logger = Logger(subsystem: logSubsystem, category: "torrent")
        let (events, continuation) = AsyncStream<TorrentEvent>.makeStream()
        relay = EventRelay(continuation: continuation)
        session = TBSession(settings: Self.bridgeSettings(settings), delegate: relay)
        // Runs until `shutdown` ends the stream.
        Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    private static func bridgeSettings(_ settings: TorrentEngineSettings) -> TBSessionSettings {
        let bridged = TBSessionSettings()
        bridged.userAgent = settings.userAgent
        bridged.listenInterfaces = settings.listenInterfaces
        bridged.connectionsLimit = settings.connectionsLimit
        bridged.downloadRateLimit = settings.downloadRateLimit
        bridged.uploadRateLimit = settings.uploadRateLimit
        bridged.usesDHT = settings.usesDHT
        bridged.usesLocalDiscovery = settings.usesLocalDiscovery
        bridged.mapsPorts = settings.mapsPorts
        bridged.allowsSeveralConnectionsPerAddress = settings.allowsSeveralConnectionsPerAddress
        bridged.diagnosticLevel = settings.diagnosticLevel
        bridged.limitsPeersOnThisMachine = settings.limitsPeersOnThisMachine
        return bridged
    }

    /// Changes limits and discovery while running.
    public func apply(_ settings: TorrentEngineSettings) {
        session.apply(Self.bridgeSettings(settings))
    }

    /// The TCP port peers can reach this engine on; 0 until it is listening.
    public var listenPort: Int {
        session.listenPort
    }

    /// The folder a torrent's data is kept in.
    public nonisolated func dataDirectory(for infoHash: String) -> URL {
        directory.appendingPathComponent(infoHash.lowercased(), isDirectory: true)
    }

    // MARK: - Torrents

    /// Starts looking for a torrent. Nothing is downloaded until a file is chosen with `open`.
    /// Adding a torrent that is already there does nothing.
    /// - Parameter folder: Where the torrent keeps its data; the engine's own folder for it
    ///   when `nil`. What is already there from an earlier session is verified and kept.
    public func add(_ source: TorrentSource, directory folder: URL? = nil) throws(TorrentError) {
        guard !isShutDown else { throw .removed }
        guard torrents[source.infoHash] == nil else { return }
        let folder = folder ?? dataDirectory(for: source.infoHash)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .couldNotAdd(error.localizedDescription)
        }
        var message: NSString?
        guard session.addTorrent(withInfoHash: source.infoHash, trackers: source.trackers, directory: folder.path, error: &message) else {
            throw .couldNotAdd((message as String?) ?? "")
        }
        torrents[source.infoHash] = Torrent()
        // Data from an earlier session may already be on disk.
        refreshMetadata(of: source.infoHash)
        lookForPeers(of: source.infoHash)
    }

    /// Shares a file that is already on disk, described by a .torrent file. Returns its info hash.
    public func seed(torrentFile: URL, dataDirectory: URL) throws(TorrentError) -> String {
        guard !isShutDown else { throw .removed }
        var message: NSString?
        guard let hash = session.addTorrentFile(torrentFile.path, directory: dataDirectory.path, error: &message) else {
            throw .couldNotAdd((message as String?) ?? "")
        }
        torrents[hash] = Torrent()
        refreshMetadata(of: hash)
        return hash
    }

    /// Stops a torrent. Everything waiting on it fails with `TorrentError.removed`.
    public func remove(_ infoHash: String, deletingData: Bool) {
        guard let torrent = torrents.removeValue(forKey: infoHash) else { return }
        fail(torrent, with: TorrentError.removed)
        session.removeTorrent(infoHash, deletingFiles: deletingData)
    }

    public func status(of infoHash: String) -> TorrentStatus? {
        guard let torrent = torrents[infoHash], let status = session.status(ofTorrent: infoHash) else { return nil }
        return TorrentStatus(
            hasMetadata: status.hasMetadata,
            downloadRate: status.downloadRate,
            uploadRate: status.uploadRate,
            peers: status.connectedPeers,
            seeds: status.connectedSeeds,
            wantedBytes: status.wantedBytes,
            wantedBytesDone: status.wantedBytesDone,
            isFinished: status.isFinished,
            isChecking: status.isChecking,
            errorMessage: torrent.failure ?? status.errorMessage
        )
    }

    /// The pieces that arrived since the torrent was added, in order (the last few hundred).
    /// What the engine was asked for first should be what came first.
    public func arrivalOrder(of infoHash: String) -> [Int] {
        torrents[infoHash]?.arrivals ?? []
    }

    /// Info hashes of the torrents the engine currently has.
    public var activeTorrents: Set<String> {
        Set(torrents.keys)
    }

    /// Tells a torrent about a peer directly, without waiting for it to be discovered.
    public func connect(_ infoHash: String, toPeerAt address: String, port: Int) {
        session.connectTorrent(infoHash, toPeerAtAddress: address, port: port)
    }

    /// The torrent's description, waiting for a peer to send it if need be.
    public func metadata(of infoHash: String, timeout: Duration = .seconds(60)) async throws -> TorrentInfo {
        guard let torrent = torrents[infoHash] else { throw TorrentError.removed }
        if let info = torrent.info {
            return info
        }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.resumeMetadataWaiter(id, of: infoHash, with: .failure(TorrentError.metadataTimeout))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Asked again here: the description may have arrived between the check above and now.
                if let info = torrents[infoHash]?.info {
                    continuation.resume(returning: info)
                } else if torrents[infoHash] == nil {
                    continuation.resume(throwing: TorrentError.removed)
                } else {
                    torrents[infoHash]?.metadataWaiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resumeMetadataWaiter(id, of: infoHash, with: .failure(CancellationError()))
            }
        }
    }

    /// Chooses the file to play: it becomes the only file downloaded, starting with both of its ends.
    /// - Parameter fetchesWholeFile: `false` fetches only around where the player reads, for a
    ///   file too large to keep whole.
    public func open(file index: Int, of infoHash: String, fetchesWholeFile: Bool = true) throws(TorrentError) -> PieceMap {
        guard let info = torrents[infoHash]?.info else { throw .removed }
        guard let map = info.pieceMap(forFile: index) else { throw .noSuchFile }
        if torrents[infoHash]?.streams[index] == nil {
            session.wantOnlyFile(index, ofTorrent: infoHash)
            torrents[infoHash]?.completed = Set(session.completedPieces(ofTorrent: infoHash).map(\.self))
            var stream = FileStream(map: map, fetchesWholeFile: fetchesWholeFile)
            let completed = torrents[infoHash]?.completed ?? []
            stream.awaited = PiecePrioritizer.edgePieces(map: map, window: window).subtracting(completed)
            torrents[infoHash]?.streams[index] = stream
            replan(file: index, of: infoHash)
        }
        return map
    }

    // MARK: - Reading

    /// Up to `maxLength` bytes of a file starting at `offset`, waiting for the piece that
    /// holds them. The pieces from here on become the ones fetched first.
    public func read(file index: Int, of infoHash: String, at offset: Int64, maxLength: Int, reader: UUID) async throws -> Data {
        guard let stream = torrents[infoHash]?.streams[index] else { throw TorrentError.removed }
        let map = stream.map
        guard offset >= 0, offset < map.fileSize, maxLength > 0 else { return Data() }

        activity += 1
        torrents[infoHash]?.streams[index]?.readers[reader] = Reader(offset: offset, lastActive: activity)
        let piece = map.piece(containing: offset)
        if stream.plannedPieces[reader] != piece {
            torrents[infoHash]?.streams[index]?.plannedPieces[reader] = piece
            replan(file: index, of: infoHash)
        }

        if torrents[infoHash]?.completed.contains(piece) == false {
            torrents[infoHash]?.streams[index]?.awaited.insert(piece)
        }
        try await waitForPiece(piece, of: infoHash)
        let data = try await pieceData(piece, of: infoHash)
        let start = map.offsetInPiece(of: offset)
        let count = min(data.count - start, maxLength, Int(min(map.fileSize - offset, Int64(Int.max))))
        guard count > 0 else { throw TorrentError.failed("A piece was shorter than expected.") }
        return data.subdata(in: data.startIndex + start ..< data.startIndex + start + count)
    }

    /// A reader has stopped: its part of the file is no longer fetched ahead of the rest.
    public func close(reader: UUID, file index: Int, of infoHash: String) {
        guard torrents[infoHash]?.streams[index]?.readers.removeValue(forKey: reader) != nil else { return }
        torrents[infoHash]?.streams[index]?.plannedPieces[reader] = nil
        replan(file: index, of: infoHash)
    }

    /// Stops the session and fails everything that is waiting. The engine cannot be used afterwards.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        watchTask?.cancel()
        watchTask = nil
        for torrent in torrents.values {
            fail(torrent, with: TorrentError.removed)
        }
        torrents = [:]
        relay.finish()
        // Closing the session waits for its threads; not on the actor.
        let session = SessionBox(session)
        Task.detached(priority: .utility) {
            session.value.shutdown()
        }
    }

    // MARK: - Internals

    func replan(file index: Int, of infoHash: String) {
        guard let torrent = torrents[infoHash], let stream = torrent.streams[index] else { return }
        let readers = stream.readers.values.sorted { $0.lastActive > $1.lastActive }.map(\.offset)
        let plan = PiecePrioritizer.plan(map: stream.map, readers: readers, window: window, fetchesWholeFile: stream.fetchesWholeFile) {
            torrent.completed.contains($0)
        }
        let changes = plan.changes(from: stream.plan)
        torrents[infoHash]?.streams[index]?.plan = plan
        guard !changes.isEmpty else { return }
        session.setDeadlines(
            Dictionary(uniqueKeysWithValues: changes.deadlinesToSet.map { (NSNumber(value: $0.key), NSNumber(value: $0.value)) }),
            clearDeadlines: changes.deadlinesToClear.map { NSNumber(value: $0) },
            priorities: Dictionary(uniqueKeysWithValues: changes.prioritiesToSet.map { (NSNumber(value: $0.key), NSNumber(value: $0.value.rawValue)) }),
            ofTorrent: infoHash
        )
    }

    private func waitForPiece(_ piece: Int, of infoHash: String) async throws {
        guard let torrent = torrents[infoHash] else { throw TorrentError.removed }
        if let failure = torrent.failure {
            throw TorrentError.failed(failure)
        }
        if torrent.completed.contains(piece) {
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                torrents[infoHash]?.pieceWaiters[piece, default: []].append(Waiter(id: id, continuation: continuation))
                if torrents[infoHash]?.waitingSince[piece] == nil {
                    torrents[infoHash]?.waitingSince[piece] = .now
                }
                startWatching()
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPieceWaiter(id, piece: piece, of: infoHash)
            }
        }
    }

    private func pieceData(_ piece: Int, of infoHash: String) async throws -> Data {
        if let cached = torrents[infoHash]?.cachedPieces.first(where: { $0.piece == piece }) {
            return cached.data
        }
        let isFirstToAsk = torrents[infoHash]?.readWaiters[piece] == nil
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                guard torrents[infoHash] != nil else {
                    continuation.resume(throwing: TorrentError.removed)
                    return
                }
                torrents[infoHash]?.readWaiters[piece, default: []].append(Waiter(id: id, continuation: continuation))
                if isFirstToAsk {
                    session.readPiece(piece, ofTorrent: infoHash)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelReadWaiter(id, piece: piece, of: infoHash)
            }
        }
    }
}

/// Carries the session to the task that closes it. The bridge is safe to call from any thread.
private struct SessionBox: @unchecked Sendable {
    let value: TBSession

    init(_ value: TBSession) {
        self.value = value
    }
}

/// A file inside a torrent, as something the stream server can read from.
public struct TorrentByteSource: ByteSource {
    public let size: Int64
    let engine: TorrentEngine
    let infoHash: String
    let fileIndex: Int

    public init(engine: TorrentEngine, infoHash: String, fileIndex: Int, size: Int64) {
        self.engine = engine
        self.infoHash = infoHash
        self.fileIndex = fileIndex
        self.size = size
    }

    public func read(at offset: Int64, maxLength: Int, reader: UUID) async throws -> Data {
        try await engine.read(file: fileIndex, of: infoHash, at: offset, maxLength: maxLength, reader: reader)
    }

    public func close(reader: UUID) async {
        await engine.close(reader: reader, file: fileIndex, of: infoHash)
    }
}

/// Makes .torrent files. The app never needs to; tests do, to share generated files between
/// two engines on this machine.
public enum TorrentCreator {
    /// Writes a .torrent file describing one file on disk and returns its info hash.
    public static func makeTorrent(forFile file: URL, pieceLength: Int = 256 * 1024, output: URL) throws(TorrentError) -> String {
        var message: NSString?
        guard let hash = TBSession.createTorrent(forFile: file.path, pieceLength: pieceLength, output: output.path, error: &message) else {
            throw .couldNotAdd((message as String?) ?? "")
        }
        return hash
    }
}
