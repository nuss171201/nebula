import AppKit
import Foundation
import MediaCore
import MediaLibrary
import Observation
import PlayerKit
import StreamEngine

/// The video a stream list is for.
public struct StreamVideo: Sendable, Hashable {
    public var type: MediaType
    /// The title's id for a film; the episode's id for a series.
    public var videoID: String
    /// The film or series.
    public var titleID: String
    /// What to call it while it is being prepared.
    public var title: String
    /// The film's or series' own name and poster, for the watch history.
    public var titleName: String
    public var poster: URL?
    public var season: Int?
    public var episode: Int?
    public var episodeTitle: String?

    public init(
        type: MediaType,
        videoID: String,
        titleID: String,
        title: String,
        titleName: String? = nil,
        poster: URL? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        episodeTitle: String? = nil
    ) {
        self.type = type
        self.videoID = videoID
        self.titleID = titleID
        self.title = title
        self.titleName = titleName ?? title
        self.poster = poster
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
    }

    /// The video as the watch history files it.
    public var watchVideo: WatchVideo {
        WatchVideo(
            type: type, videoID: videoID, titleID: titleID, titleName: titleName,
            poster: poster, season: season, episode: episode, videoTitle: episodeTitle
        )
    }

    /// Names the player remembers this video's tracks and position under. A stream's address
    /// changes every time, so the video's identity is used instead: the episode, then the series.
    var memoryKeys: [String] {
        [WatchKey.make(type: type, videoID: videoID), "title:\(type.rawValue):\(titleID)"]
    }
}

/// Last-used stream sources, kept in the app's database.
struct LibraryStreamChoiceMemory: StreamChoiceMemory {
    let store: PlaybackMemoryStore

    func lastChoice(for titleID: String) async -> LastStreamChoice? {
        try? await store.value(forAnyOf: ["stream|" + titleID], as: LastStreamChoice.self)
    }

    func remember(_ choice: LastStreamChoice, for titleID: String) async {
        try? await store.set(choice, for: ["stream|" + titleID])
    }
}

/// Plays a stream chosen from the list: a torrent through the stream engine, a web address
/// directly, a YouTube video in its embedded player, anything else in the browser.
@MainActor
@Observable
public final class StreamPlayer {
    public enum Phase: Equatable, Sendable {
        case idle
        /// A torrent is being found; `detail` says how that is going.
        case preparing(title: String, detail: String)
        case failed(title: String, message: String)
    }

    public internal(set) var phase = Phase.idle
    /// A YouTube stream waiting to be shown in the embedded player.
    var youTubeVideo: YouTubeVideoID?
    /// The torrent being played, if the player is on one.
    public private(set) var activeTorrent: String?

    @ObservationIgnored let coordinator: PlayerCoordinator
    @ObservationIgnored private let manager: StreamManager
    @ObservationIgnored private let library: LibraryCenter?
    /// The video that was last handed to the player, for whoever decides what comes after it.
    public internal(set) var nowPlaying: StreamVideo?
    /// The stream it was played from.
    public internal(set) var nowPlayingChoice: StreamChoice?
    @ObservationIgnored private let openExternal: @MainActor (URL) -> Void
    @ObservationIgnored private let subtitleService: AddonSubtitleService?
    @ObservationIgnored var prepareTask: Task<Void, Never>?
    @ObservationIgnored var activeURL: URL?
    @ObservationIgnored var automaticTask: Task<Void, Never>?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    @ObservationIgnored private var speedSamples: [Double] = []
    /// Called when a torrent stream closes, with the best download rate it held for a few
    /// seconds (bytes a second): what the app learns the connection's speed from.
    @ObservationIgnored public var onSessionSpeed: (@MainActor (Double) -> Void)?
    /// How long an automatically chosen stream gets to show its first picture before the next is tried.
    @ObservationIgnored var startTimeout: (torrent: Duration, direct: Duration) = (.seconds(30), .seconds(20))
    /// How often a playing torrent's download rate is read.
    @ObservationIgnored var speedSampleInterval = Duration.seconds(2)
    /// At most this many streams are tried when Play chooses.
    static let automaticAttempts = 3

    /// - Parameters:
    ///   - subtitleService: Told about subtitles that come with a stream, so the player can offer them.
    ///   - openExternal: Opens a web page outside the app.
    public init(
        coordinator: PlayerCoordinator,
        manager: StreamManager,
        library: LibraryCenter? = nil,
        subtitleService: AddonSubtitleService? = nil,
        openExternal: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.subtitleService = subtitleService
        self.coordinator = coordinator
        self.manager = manager
        self.library = library
        self.openExternal = openExternal
        watchPlayer()
    }

    public func play(_ choice: StreamChoice, for video: StreamVideo) {
        cancel()
        start(choice, for: video)
    }

    func start(_ choice: StreamChoice, for video: StreamVideo) {
        prepareTask?.cancel()
        prepareTask = nil
        phase = .idle
        switch choice.stream.source {
        case let .url(url):
            playDirect(url, choice: choice, video: video)
        case let .torrent(infoHash, fileIndex):
            playTorrent(infoHash: infoHash, fileIndex: fileIndex, choice: choice, video: video)
        case let .youTube(id):
            if let video = YouTubeVideoID(id) {
                youTubeVideo = video
            } else {
                phase = .failed(title: video.title, message: "This stream points to a YouTube video that cannot be shown.")
            }
        case let .external(url):
            // Only ever a web page: an add-on must not be able to open other things on the Mac.
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                openExternal(url)
            } else {
                phase = .failed(title: video.title, message: "This stream points to something that is not a web page.")
            }
        }
    }

    /// Stops looking for a torrent that has not started playing, and clears any message.
    public func cancel() {
        automaticTask?.cancel()
        automaticTask = nil
        prepareTask?.cancel()
        prepareTask = nil
        phase = .idle
    }

    /// Waits for a stream that is being prepared. For tests.
    func waitUntilPrepared() async {
        await prepareTask?.value
    }

    /// Waits until Play has settled on a stream or given up. For tests.
    func waitForAutomaticPlay() async {
        await automaticTask?.value
    }

    // MARK: - Kinds of stream

    private func playDirect(_ url: URL, choice: StreamChoice, video: StreamVideo) {
        do {
            let source = try PlayableSource(url: url)
            closeActiveTorrent()
            noteStarted(video, choice: choice)
            coordinator.play(source, options: PlaybackOptions(
                memoryKeys: video.memoryKeys,
                httpHeaders: choice.stream.behaviorHints.requestHeaders,
                title: video.title
            ))
        } catch {
            phase = .failed(title: video.title, message: error.userMessage)
        }
    }

    private func playTorrent(infoHash: String, fileIndex: Int?, choice: StreamChoice, video: StreamVideo) {
        // Add-ons list trackers as "tracker:<address>"; other hints (the hash table) need nothing from us.
        let trackers = choice.stream.peerSources.compactMap { $0.hasPrefix("tracker:") ? String($0.dropFirst("tracker:".count)) : nil }
        guard let source = TorrentSource(infoHash: infoHash, trackers: trackers) else {
            phase = .failed(title: video.title, message: TorrentError.invalidSource.userMessage)
            return
        }
        phase = .preparing(title: video.title, detail: "Looking for people sharing this…")
        prepareTask = Task { [weak self, manager] in
            let progress = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled, let status = await manager.status(of: source.infoHash) else { continue }
                    self?.reportProgress(status, title: video.title)
                }
            }
            defer { progress.cancel() }
            let result: Result<OpenedStream, any Error>
            do {
                result = try await .success(manager.open(source, fileIndex: fileIndex, fileName: choice.stream.behaviorHints.filename))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else {
                // Given up on while it was being found: do not leave it running.
                if case .success = result {
                    await manager.close(source.infoHash)
                }
                return
            }
            finishPreparing(result, infoHash: source.infoHash, video: video, choice: choice)
        }
    }

    /// Files the video in the watch history before the player asks where it was left.
    private func noteStarted(_ video: StreamVideo, choice: StreamChoice) {
        nowPlaying = video
        nowPlayingChoice = choice
        subtitleService?.setAttached(choice.stream.subtitles, forVideo: video.videoID)
        if let library {
            Task { await library.begin(video.watchVideo) }
        }
    }

    private func finishPreparing(_ result: Result<OpenedStream, any Error>, infoHash: String, video: StreamVideo, choice: StreamChoice) {
        switch result {
        case let .success(stream):
            guard let playable = try? PlayableSource(url: stream.url) else {
                phase = .failed(title: video.title, message: "The stream could not be started.")
                return
            }
            if activeTorrent != infoHash {
                closeActiveTorrent()
            }
            activeTorrent = infoHash
            activeURL = stream.url
            sampleSpeed(of: infoHash)
            phase = .idle
            noteStarted(video, choice: choice)
            // No seek-bar stills: they would open a second reader far from the playhead and
            // take pieces from what is about to be watched.
            coordinator.play(playable, options: PlaybackOptions(
                memoryKeys: video.memoryKeys,
                generatesThumbnails: false,
                title: video.title,
                arrivalFailureMessage: Self.didNotArriveMessage
            ))
        case let .failure(error as TorrentError):
            phase = .failed(title: video.title, message: error.userMessage)
        case .failure(is CancellationError):
            phase = .idle
        case .failure:
            phase = .failed(title: video.title, message: "The stream could not be started.")
        }
    }

    private func reportProgress(_ status: TorrentStatus, title: String) {
        guard case .preparing = phase else { return }
        phase = .preparing(title: title, detail: Self.progressText(for: status))
    }

    nonisolated static func progressText(for status: TorrentStatus) -> String {
        guard status.hasMetadata else {
            return status.peers > 0
                ? "Connected to \(status.peers) \(status.peers == 1 ? "person" : "people") sharing this…"
                : "Looking for people sharing this…"
        }
        let speed = ByteCountFormatter.string(fromByteCount: Int64(status.downloadRate), countStyle: .file)
        return "Starting: \(status.peers) \(status.peers == 1 ? "connection" : "connections"), \(speed)/s"
    }

    // MARK: - Following the player

    /// When the player closes, or moves on to something else, the torrent behind it is stopped.
    private func watchPlayer() {
        let (isOpen, playing) = withObservationTracking {
            (coordinator.isPlayerOpen, coordinator.player?.source?.url)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.watchPlayer()
            }
        }
        if activeTorrent != nil, !isOpen || (playing != nil && playing != activeURL) {
            closeActiveTorrent()
        }
        if !isOpen {
            nowPlaying = nil
            nowPlayingChoice = nil
        }
    }

    /// Reads the torrent's download rate every so often for as long as it is the one playing.
    private func sampleSpeed(of infoHash: String) {
        speedTask?.cancel()
        speedSamples = []
        speedTask = Task { [weak self, manager] in
            while !Task.isCancelled {
                guard let interval = self?.speedSampleInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let status = await manager.status(of: infoHash) else { continue }
                guard let self, activeTorrent == infoHash else { return }
                // A finished file downloads nothing more, which says nothing about the connection.
                if !status.isFinished {
                    speedSamples.append(Double(status.downloadRate))
                }
                showWaitingNote(for: status)
            }
        }
    }

    /// What the player says if a torrent's file never opens.
    nonisolated static let didNotArriveMessage =
        "This stream did not arrive. Too few people may be sharing it at the moment, or the connection to them is too slow. Try another one."

    /// While the player is waiting for the torrent, says under its busy indicator how the
    /// torrent is doing. Only then: during ordinary playback nothing is written, so nothing redraws.
    private func showWaitingNote(for status: TorrentStatus) {
        guard let player = coordinator.player else { return }
        let note = player.state.isBusy ? Self.waitingNote(for: status) : nil
        if player.waitingNote != note {
            player.waitingNote = note
        }
    }

    nonisolated static func waitingNote(for status: TorrentStatus) -> String {
        guard status.peers > 0 else { return "Looking for people sharing this…" }
        let speed = ByteCountFormatter.string(fromByteCount: Int64(status.downloadRate), countStyle: .file)
        return "\(status.peers) \(status.peers == 1 ? "connection" : "connections") · \(speed)/s"
    }

    func closeActiveTorrent() {
        guard let infoHash = activeTorrent else { return }
        speedTask?.cancel()
        speedTask = nil
        let best = ConnectionSpeed.bestSustained(speedSamples)
        speedSamples = []
        if best > 0 {
            onSessionSpeed?(best)
        }
        activeTorrent = nil
        activeURL = nil
        Task { [manager] in
            await manager.close(infoHash)
        }
    }
}
