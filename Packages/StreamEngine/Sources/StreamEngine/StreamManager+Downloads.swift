import Foundation

/// A torrent's file to keep for good.
public struct DownloadRequest: Sendable, Equatable {
    public var source: TorrentSource
    /// The file's number in the torrent, if the stream says.
    public var fileIndex: Int?
    /// The file's name, if the stream says.
    public var fileName: String?
    /// Where the torrent keeps its data while it is fetched: a folder of its own, outside the
    /// cache, so that clearing the cache never takes it.
    public var directory: URL

    public init(source: TorrentSource, fileIndex: Int? = nil, fileName: String? = nil, directory: URL) {
        self.source = source
        self.fileIndex = fileIndex
        self.fileName = fileName
        self.directory = directory
    }
}

/// A moment's reading of the download.
public struct DownloadReading: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Something is playing from a torrent; the download waits for it to finish, so that
        /// it does not take the bandwidth the film needs.
        case waitingForPlayer
        case findingPeers
        /// What an earlier session left on disk is being verified.
        case checking
        case downloading
        /// The whole file is there.
        case finished
        /// Carries a sentence that can be shown to the user.
        case failed(String)
    }

    public var infoHash: String
    public var phase: Phase
    /// The file that was chosen, once the torrent's description has arrived.
    public var file: TorrentFile?
    /// Where the file is being written.
    public var fileURL: URL?
    public var status: TorrentStatus?
}

struct ActiveDownload {
    var request: DownloadRequest
    var phase: DownloadReading.Phase
    var file: TorrentFile?
    var task: Task<Void, Never>?
    /// Whether the engine has been given the torrent (and not had it taken away again).
    var isInEngine = false
    /// Changes whenever the download is started, held or stopped, so that work begun for an
    /// earlier state can tell it has been overtaken.
    var generation: Int
}

/// Keeping a file: one download at a time, fetched whole and in file order, in a folder of
/// its own.
///
/// A download and a stream never run side by side, with one exception. A stream is watched
/// now and a download is wanted later, so while anything plays from a torrent the download is
/// taken out of the engine (its data stays) and put back when the player closes. The exception
/// is a stream of the very file being downloaded: it reads from the download's own torrent,
/// which goes on fetching the rest.
public extension StreamManager {
    /// How long a download looks for someone sharing its torrent before giving up. Longer than a
    /// stream's: nobody is sitting in front of it.
    static let downloadMetadataTimeout = Duration.seconds(180)

    /// Starts keeping a file, in place of whatever was being kept before (whose data stays
    /// where it is). Returns at once; `downloadReading()` says how it is going.
    func startDownload(_ request: DownloadRequest) async {
        await stopDownload(deletingData: false)
        downloadGeneration += 1
        download = ActiveDownload(request: request, phase: .waitingForPlayer, generation: downloadGeneration)
        resumeDownloadIfIdle()
    }

    /// How the download is doing; `nil` when there is none.
    func downloadReading() async -> DownloadReading? {
        guard let current = download else { return nil }
        let hash = current.request.source.infoHash
        var reading = DownloadReading(
            infoHash: hash,
            phase: current.phase,
            file: current.file,
            fileURL: current.file.map { current.request.directory.appendingPathComponent($0.path) }
        )
        guard current.isInEngine, let status = await engine?.status(of: hash) else { return reading }
        reading.status = status
        guard current.phase == .downloading, download?.generation == current.generation else { return reading }
        if let message = status.errorMessage {
            await failDownload(TorrentError.failed(message).userMessage, generation: current.generation)
            reading.phase = download?.phase ?? reading.phase
        } else if status.isChecking {
            reading.phase = .checking
        } else if status.wantedBytes > 0, status.wantedBytesDone >= status.wantedBytes {
            // "Wanted" is nothing at all until the choice of file has taken effect, which is why
            // an empty wish does not count as a finished one.
            download?.phase = .finished
            reading.phase = .finished
        }
        return reading
    }

    /// Lets go of a finished download, so that its file can be moved to where it is kept.
    /// Returns `false`, and changes nothing, while the player is still reading from it.
    func releaseFinishedDownload() async -> Bool {
        guard let current = download, current.phase == .finished else { return false }
        let hash = current.request.source.infoHash
        guard !streamsOnDownload.contains(hash) else { return false }
        download = nil
        await engine?.remove(hash, deletingData: false)
        return true
    }

    /// Stops the download. A stream reading from it is stopped with it.
    /// - Parameter deletingData: Whether what has been fetched is deleted as well.
    func stopDownload(deletingData: Bool) async {
        guard let current = download else { return }
        let hash = current.request.source.infoHash
        current.task?.cancel()
        download = nil
        if streamsOnDownload.remove(hash) != nil, let stream = opened.removeValue(forKey: hash) {
            await server?.withdraw(stream.url)
        }
        if current.isInEngine {
            await engine?.remove(hash, deletingData: deletingData)
        }
        if deletingData {
            try? FileManager.default.removeItem(at: current.request.directory)
        }
    }
}

extension StreamManager {
    /// Starts the download if it is waiting and nothing is playing or about to.
    func resumeDownloadIfIdle() {
        guard opened.isEmpty, opening == 0, var current = download, current.phase == .waitingForPlayer else { return }
        downloadGeneration += 1
        let generation = downloadGeneration
        current.generation = generation
        current.phase = .findingPeers
        current.task = Task { await self.runDownload(generation) }
        download = current
    }

    /// Takes a running download out of the engine until nothing is playing. Its data stays.
    func holdDownload() async {
        guard var current = download else { return }
        switch current.phase {
        case .waitingForPlayer, .finished, .failed: return
        case .findingPeers, .checking, .downloading: break
        }
        current.task?.cancel()
        current.task = nil
        downloadGeneration += 1
        current.generation = downloadGeneration
        current.phase = .waitingForPlayer
        let wasInEngine = current.isInEngine
        current.isInEngine = false
        download = current
        if wasInEngine {
            await engine?.remove(current.request.source.infoHash, deletingData: false)
        }
    }

    /// A stream of the file that is being downloaded: served from the download's torrent,
    /// which goes on fetching the rest. `nil` for anything else.
    func openOnDownload(_ source: TorrentSource, fileIndex: Int?, fileName: String?) async throws -> OpenedStream? {
        // Finished counts too: until its file has been moved away, the torrent is where it is.
        guard let current = download, current.isInEngine, current.phase == .downloading || current.phase == .finished,
              current.request.source.infoHash == source.infoHash,
              let file = current.file, let engine,
              let info = try? await engine.metadata(of: source.infoHash),
              TorrentFileChooser.choose(from: info.files, index: fileIndex, name: fileName)?.index == file.index
        else { return nil }
        let server = try await startServer()
        // Held or stopped while the server was starting: play it the ordinary way.
        guard download?.generation == current.generation else { return nil }
        let map = try await engine.open(file: file.index, of: source.infoHash, fetchesWholeFile: true)
        let byteSource = TorrentByteSource(engine: engine, infoHash: source.infoHash, fileIndex: file.index, size: map.fileSize)
        let url = try await server.publish(byteSource, named: file.name)
        let stream = OpenedStream(infoHash: source.infoHash, file: file, url: url, fetchesWholeFile: true)
        opened[source.infoHash] = stream
        streamsOnDownload.insert(source.infoHash)
        return stream
    }

    private func runDownload(_ generation: Int) async {
        guard let request = download?.request, download?.generation == generation else { return }
        let hash = request.source.infoHash
        do {
            let engine = try startEngine()
            adoptCachedData(of: hash, into: request.directory)
            download?.isInEngine = true
            try await engine.add(request.source, directory: request.directory)
            let info = try await engine.metadata(of: hash, timeout: Self.downloadMetadataTimeout)
            guard download?.generation == generation else { return }
            guard let file = TorrentFileChooser.choose(from: info.files, index: request.fileIndex, name: request.fileName) else {
                throw TorrentError.noSuchFile
            }
            _ = try await engine.open(file: file.index, of: hash, fetchesWholeFile: true)
            guard download?.generation == generation else { return }
            download?.file = file
            download?.phase = .downloading
        } catch {
            let message = (error as? TorrentError)?.userMessage ?? "The download could not be started."
            await failDownload(message, generation: generation)
        }
    }

    /// Ends the download with a message, unless it has been held or stopped meanwhile (which
    /// is what a torrent being taken away looks like from inside).
    func failDownload(_ message: String, generation: Int) async {
        guard var current = download, current.generation == generation else { return }
        current.phase = .failed(message)
        let wasInEngine = current.isInEngine
        current.isInEngine = false
        download = current
        if wasInEngine {
            // What has arrived is kept: trying again goes on from there.
            await engine?.remove(current.request.source.infoHash, deletingData: false)
        }
    }

    /// What was streamed of this torrent is the start of its download: the cache's folder for
    /// it becomes the download's, unless the download already has data of its own. (A folder
    /// alone does not count: one is made the moment a download starts, before anything arrives.)
    private func adoptCachedData(of infoHash: String, into directory: URL) {
        let files = FileManager.default
        let cached = cache.directory.appendingPathComponent(infoHash, isDirectory: true)
        guard files.fileExists(atPath: cached.path), StreamCache.allocatedSize(of: directory, fileManager: files) == 0 else { return }
        try? files.removeItem(at: directory)
        try? files.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.moveItem(at: cached, to: directory)
    }
}
