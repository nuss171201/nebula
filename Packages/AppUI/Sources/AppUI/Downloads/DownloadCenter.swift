import Foundation
import MediaCore
import MediaLibrary
import Observation
import os
import StreamEngine

/// The files the user keeps for watching without a connection: what was asked for, how each
/// is coming along, and where the finished ones are.
///
/// Downloads run one at a time, in the order they were asked for. A torrent is fetched by the
/// stream engine into a folder of its own (`.incomplete` inside the downloads folder) and its
/// file is moved next to the others when it is whole; a file on a web server is fetched
/// directly. While something plays from a torrent, a torrent download gives way to it (the
/// engine sees to that; here it shows as "waiting until nothing is playing").
@MainActor
@Observable
public final class DownloadCenter {
    /// Every download, oldest first.
    public private(set) var items: [DownloadItem] = []

    /// Where finished files are kept.
    @ObservationIgnored public let directory: URL
    @ObservationIgnored private let manager: StreamManager
    @ObservationIgnored private let store: DownloadStore?
    @ObservationIgnored private let userAgent: String
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var activeID: String?
    @ObservationIgnored private var hasLoaded = false
    /// What an interrupted web download left to go on from. Kept for the session only.
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    /// The last reading of a web download, for working out its speed.
    @ObservationIgnored private var lastSample: (bytes: Int64, at: ContinuousClock.Instant)?
    @ObservationIgnored private var readingsSinceSave = 0
    /// How often a torrent download is looked in on.
    @ObservationIgnored var pollInterval = Duration.seconds(1)
    /// How often a web download that lost its connection is tried again.
    @ObservationIgnored var retryPolicy = RetryPolicy(maxAttempts: 4, baseDelay: .seconds(1), maxDelay: .seconds(15))
    /// What becomes of a finished file whose download is removed: the Trash, where it can be
    /// got back from (a film is hours of downloading). Tests delete instead, so as not to
    /// leave their files in the user's Trash.
    @ObservationIgnored var discardFile: @MainActor (URL) -> Void = { file in
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Progress is written to disk once in this many readings; a change of stage always is.
    static let readingsPerSave = 15

    /// - Parameters:
    ///   - store: Where the list is kept between launches; `nil` keeps it for the session only.
    ///   - directory: Where finished files go.
    public init(manager: StreamManager, store: DownloadStore?, directory: URL, userAgent: String, logSubsystem: String = "downloads") {
        self.manager = manager
        self.store = store
        self.directory = directory
        self.userAgent = userAgent
        logger = Logger(subsystem: logSubsystem, category: "downloads")
    }

    /// With the app's own engine, list and folder.
    public convenience init(dependencies: AppDependencies) {
        self.init(
            manager: dependencies.streamManager,
            store: dependencies.downloadStore,
            directory: dependencies.downloadsDirectory,
            userAgent: dependencies.branding.userAgent,
            logSubsystem: dependencies.branding.bundleIdentifier
        )
    }

    /// Where a torrent keeps its data until its file is whole.
    var incompleteDirectory: URL {
        directory.appendingPathComponent(".incomplete", isDirectory: true)
    }

    // MARK: - Reading

    /// Reads the list from disk and carries on with whatever was under way. Safe to call again.
    public func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        var stored: [DownloadItem] = []
        do {
            stored = try await store?.all(as: DownloadItem.self) ?? []
        } catch {
            logger.error("downloads could not be read: \(error.localizedDescription, privacy: .public)")
        }
        for index in stored.indices where stored[index].stage == .finished {
            // Moved or deleted in the Finder since: it is no longer something that can be played.
            if let file = stored[index].fileURL, !FileManager.default.fileExists(atPath: file.path) {
                stored[index].stage = .failed
                stored[index].failure = "The file is no longer where it was saved."
            }
        }
        // Anything asked for before the list was read comes after what was already there.
        items = stored + items.filter { added in !stored.contains { $0.id == added.id } }
        pump()
    }

    /// The download for a video, if it has one.
    public func item(for video: StreamVideo) -> DownloadItem? {
        items.last { $0.isFor(video) }
    }

    /// The downloaded file of a video, if it is whole and still there.
    public func finishedFile(for video: StreamVideo) -> URL? {
        guard let item = item(for: video), item.stage == .finished, let file = item.fileURL,
              FileManager.default.fileExists(atPath: file.path)
        else { return nil }
        return file
    }

    /// How many downloads are under way or waiting their turn.
    public var pendingCount: Int {
        items.count { $0.stage == .queued }
    }

    /// Whether a stream is of a kind that can be downloaded: a torrent, or one file on a web server.
    public nonisolated static func canDownload(_ choice: StreamChoice) -> Bool {
        DownloadItem.Source(choice.stream) != nil
    }

    // MARK: - Intents

    /// Starts keeping a stream's file. A video has one download: asking again returns the one
    /// it has (setting a paused one going), unless that one failed, which is replaced.
    /// Returns `nil` for a stream that cannot be downloaded.
    @discardableResult
    public func add(_ choice: StreamChoice, for video: StreamVideo) -> DownloadItem? {
        guard let source = DownloadItem.Source(choice.stream) else { return nil }
        if let existing = item(for: video) {
            switch existing.stage {
            case .finished, .queued:
                return existing
            case .paused:
                resume(existing.id)
                return item(for: video)
            case .failed:
                remove(existing.id)
            }
        }
        let summary = [choice.quality?.label, choice.sizeText, choice.addonName].compactMap(\.self).joined(separator: " · ")
        let item = DownloadItem(video: video, summary: summary, source: source, bytesTotal: choice.sizeBytes)
        items.append(item)
        save(item)
        pump()
        return item
    }

    /// Stops a download until `resume`. What has arrived is kept.
    public func pause(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].stage == .queued else { return }
        items[index].stage = .paused
        items[index].activity = nil
        save(items[index])
        if activeID == id {
            // The run sees that it was paused, and lets go of the engine on its way out.
            runTask?.cancel()
        }
    }

    /// Puts a paused or failed download back in the queue.
    public func resume(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].stage == .paused || items[index].stage == .failed else { return }
        items[index].stage = .queued
        items[index].failure = nil
        save(items[index])
        pump()
    }

    /// Forgets a download. What was fetched of an unfinished one is deleted; a finished file
    /// goes to the Trash, where it can be got back from.
    public func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        resumeData[id] = nil
        Task { [store] in
            try? await store?.remove(id: id)
        }
        if activeID == id {
            // The run sees that it is gone, and deletes what it had on its way out.
            runTask?.cancel()
        } else {
            deleteData(of: item)
        }
    }

    /// Waits until nothing is under way. For tests.
    func waitUntilIdle() async {
        while let task = runTask {
            await task.value
        }
    }
}

// MARK: - Running

private extension DownloadCenter {
    /// Starts the next download in the queue, if none is running.
    func pump() {
        guard hasLoaded, runTask == nil, let next = items.first(where: { $0.stage == .queued }) else { return }
        activeID = next.id
        lastSample = nil
        readingsSinceSave = 0
        runTask = Task { [weak self] in
            await self?.run(next)
            guard let self else { return }
            runTask = nil
            activeID = nil
            pump()
        }
    }

    func run(_ item: DownloadItem) async {
        switch item.source {
        case let .torrent(infoHash, fileIndex, fileName, trackers):
            guard let source = TorrentSource(infoHash: infoHash, trackers: trackers) else {
                fail(item.id, TorrentError.invalidSource.userMessage)
                return
            }
            await runTorrent(item.id, source: source, fileIndex: fileIndex, fileName: fileName)
        case let .direct(url, headers):
            await runDirect(item.id, url: url, headers: headers)
        }
    }

    func runTorrent(_ id: String, source: TorrentSource, fileIndex: Int?, fileName: String?) async {
        let folder = incompleteDirectory.appendingPathComponent(source.infoHash, isDirectory: true)
        await manager.startDownload(DownloadRequest(source: source, fileIndex: fileIndex, fileName: fileName, directory: folder))
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { break }
            guard let reading = await manager.downloadReading(), reading.infoHash == source.infoHash else {
                fail(id, "The download was stopped.")
                return
            }
            guard !Task.isCancelled else { break }
            note(reading, for: id)
            switch reading.phase {
            case .finished:
                // Not while the player is reading the file from the torrent: moving it would
                // take it from under the film.
                guard await manager.releaseFinishedDownload() else { continue }
                finish(id, file: reading.fileURL, partialFolder: folder)
                return
            case let .failed(message):
                await manager.stopDownload(deletingData: false)
                fail(id, message)
                return
            case .waitingForPlayer, .findingPeers, .checking, .downloading:
                continue
            }
        }
        // Paused (the data stays) or removed (it goes, unless another download is of the same torrent).
        let isRemoved = !items.contains { $0.id == id }
        let isShared = items.contains { $0.infoHash == source.infoHash }
        await manager.stopDownload(deletingData: isRemoved && !isShared)
    }

    func note(_ reading: DownloadReading, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        item.activity = switch reading.phase {
        case .waitingForPlayer: .waitingForPlayer
        case .findingPeers: .findingPeers
        case .checking: .checking
        case .downloading: .downloading(rate: reading.status?.downloadRate ?? 0, peers: reading.status?.peers ?? 0)
        case .finished: .finishing
        case .failed: nil
        }
        if let file = reading.file {
            item.bytesTotal = file.size
            // The engine counts whole pieces, and the file's first and last are shared with its neighbours.
            item.bytesDone = min(reading.status?.wantedBytesDone ?? item.bytesDone, file.size)
        }
        guard item != items[index] else { return }
        items[index] = item
        readingsSinceSave += 1
        if readingsSinceSave >= Self.readingsPerSave {
            readingsSinceSave = 0
            save(item)
        }
    }

    func runDirect(_ id: String, url: URL, headers: [String: String]) async {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        var attempt = 1
        while !Task.isCancelled {
            let download = DirectDownload(folder: incompleteDirectory) { [weak self] done, total in
                Task { @MainActor in
                    self?.noteProgress(id, done: done, total: total)
                }
            }
            do {
                let (file, suggestedName) = try await download.run(request, resumeData: resumeData[id])
                resumeData[id] = nil
                let name = Self.fileName(suggested: suggestedName, url: url, title: items.first { $0.id == id }?.video.title)
                finish(id, file: file, named: name, partialFolder: nil)
                return
            } catch let error as DirectDownloadError {
                resumeData[id] = download.resumeData
                // Only a lost connection is worth another try; a refusal would be refused again.
                guard case .network = error, let delay = retryPolicy.delay(beforeRetry: attempt) else {
                    fail(id, error.userMessage)
                    return
                }
                attempt += 1
                try? await Task.sleep(for: delay)
            } catch {
                // Paused: go on from here next time. Removed: nothing to go on with.
                resumeData[id] = items.contains { $0.id == id } ? download.resumeData : nil
                return
            }
        }
    }

    func noteProgress(_ id: String, done: Int64, total: Int64?) {
        guard activeID == id, let index = items.firstIndex(where: { $0.id == id }), items[index].stage == .queued else { return }
        let now = ContinuousClock.now
        var rate = 0
        if let lastSample, now > lastSample.at {
            rate = Int(Double(max(done - lastSample.bytes, 0)) / ((now - lastSample.at) / .seconds(1)))
        }
        lastSample = (done, now)
        items[index].bytesDone = done
        items[index].bytesTotal = total ?? items[index].bytesTotal
        items[index].activity = .downloading(rate: rate, peers: nil)
    }
}

// MARK: - Endings

private extension DownloadCenter {
    /// Puts a finished file with the others and marks its download done.
    /// - Parameters:
    ///   - name: What to call it; its own name when `nil`.
    ///   - partialFolder: The torrent's folder, deleted once its file has been taken out.
    func finish(_ id: String, file: URL?, named name: String? = nil, partialFolder: URL?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            // Removed at the last moment.
            if let file {
                try? FileManager.default.removeItem(at: file)
            }
            return
        }
        let files = FileManager.default
        guard let file, files.fileExists(atPath: file.path) else {
            fail(id, "The finished file could not be found.")
            return
        }
        let destination = Self.freeLocation(for: name ?? file.lastPathComponent, in: directory, fileManager: files)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try files.moveItem(at: file, to: destination)
        } catch {
            logger.error("a finished download could not be moved: \(error.localizedDescription, privacy: .public)")
            fail(id, "The file arrived but could not be moved to the downloads folder.")
            return
        }
        let infoHash = items[index].infoHash
        if let partialFolder, !items.contains(where: { $0.id != id && $0.infoHash == infoHash && $0.stage != .finished }) {
            try? files.removeItem(at: partialFolder)
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        items[index].stage = .finished
        items[index].activity = nil
        items[index].failure = nil
        items[index].fileURL = destination
        items[index].bytesTotal = size ?? items[index].bytesTotal
        items[index].bytesDone = items[index].bytesTotal ?? items[index].bytesDone
        save(items[index])
    }

    func fail(_ id: String, _ message: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].stage = .failed
        items[index].failure = message
        items[index].activity = nil
        save(items[index])
    }

    func save(_ item: DownloadItem) {
        Task { [store, logger] in
            do {
                try await store?.save(item, id: item.id)
            } catch {
                logger.error("a download could not be saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func deleteData(of item: DownloadItem) {
        let files = FileManager.default
        if let file = item.fileURL, files.fileExists(atPath: file.path) {
            discardFile(file)
        }
        if let infoHash = item.infoHash, !items.contains(where: { $0.infoHash == infoHash && $0.stage != .finished }) {
            try? files.removeItem(at: incompleteDirectory.appendingPathComponent(infoHash, isDirectory: true))
        }
    }
}

// MARK: - Names

extension DownloadCenter {
    /// A place in `folder` for a file called `name` that nothing occupies: the name itself,
    /// else "Name 2.ext", "Name 3.ext" and so on.
    nonisolated static func freeLocation(for name: String, in folder: URL, fileManager: FileManager = .default) -> URL {
        let safe = safeFileName(name)
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = folder.appendingPathComponent(safe)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }

    /// What to call a file fetched from a web server: the name the server gives it if that
    /// looks like a video's; else the title, with the address's extension (or `mp4`).
    nonisolated static func fileName(suggested: String?, url: URL, title: String?) -> String {
        let fromAddress = url.pathExtension.lowercased()
        if let suggested, MediaFileExtensions.video.contains((suggested as NSString).pathExtension.lowercased()) {
            return suggested
        }
        let ext = MediaFileExtensions.video.contains(fromAddress) ? fromAddress : "mp4"
        let base = title.flatMap { $0.isEmpty ? nil : $0 } ?? (url.deletingPathExtension().lastPathComponent)
        return "\(base).\(ext)"
    }

    /// A name without the characters a file name cannot have, and never empty or hidden.
    nonisolated static func safeFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = String(cleaned.drop { $0 == "." })
        return visible.isEmpty ? "Download" : visible
    }
}
