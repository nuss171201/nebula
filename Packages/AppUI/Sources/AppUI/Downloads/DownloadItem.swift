import Foundation
import MediaCore
import StreamEngine

/// One file the user asked to keep, for watching without a connection.
public struct DownloadItem: Identifiable, Sendable, Equatable, Codable {
    /// Where the file comes from.
    public enum Source: Sendable, Equatable, Codable {
        case torrent(infoHash: String, fileIndex: Int?, fileName: String?, trackers: [String])
        /// A file on a web server.
        case direct(url: URL, headers: [String: String])
    }

    /// Where the download stands. This is what is remembered between launches.
    public enum Stage: String, Sendable, Codable {
        /// Waiting its turn, or under way: downloads run one at a time.
        case queued
        /// Stopped by the user until they say otherwise. What has arrived is kept.
        case paused
        case finished
        case failed
    }

    /// What the download that is under way is doing at this moment. Never stored.
    public enum Activity: Sendable, Equatable {
        /// Something is playing from a torrent; the download gives way to it.
        case waitingForPlayer
        case findingPeers
        /// What an earlier session left on disk is being verified.
        case checking
        /// - Parameters:
        ///   - rate: Bytes a second.
        ///   - peers: How many people it is coming from; `nil` for a file on a web server.
        case downloading(rate: Int, peers: Int?)
        /// The file is there and is being put where it is kept.
        case finishing
    }

    public let id: String
    public var video: StreamVideo
    /// What was chosen, as the title's page described it: "4K · 25,8 GB · Add-on".
    public var summary: String
    public var source: Source
    public var stage: Stage
    /// Why it failed, when it did.
    public var failure: String?
    public var bytesDone: Int64
    /// The file's size, once known.
    public var bytesTotal: Int64?
    /// The finished file.
    public var fileURL: URL?
    public var addedAt: Date
    public var activity: Activity?

    private enum CodingKeys: String, CodingKey {
        case id, video, summary, source, stage, failure, bytesDone, bytesTotal, fileURL, addedAt
    }

    public init(id: String = UUID().uuidString, video: StreamVideo, summary: String, source: Source, bytesTotal: Int64? = nil, addedAt: Date = Date()) {
        self.id = id
        self.video = video
        self.summary = summary
        self.source = source
        stage = .queued
        bytesDone = 0
        self.bytesTotal = bytesTotal
        self.addedAt = addedAt
    }

    /// How much of the file is there, 0 to 1; `nil` while its size is not known.
    public var fraction: Double? {
        if stage == .finished {
            return 1
        }
        guard let bytesTotal, bytesTotal > 0 else { return nil }
        return min(max(Double(bytesDone) / Double(bytesTotal), 0), 1)
    }

    /// Whether this is the download for a video.
    public func isFor(_ video: StreamVideo) -> Bool {
        self.video.type == video.type && self.video.videoID == video.videoID
    }

    /// The torrent it comes from, if it comes from one.
    var infoHash: String? {
        if case let .torrent(infoHash, _, _, _) = source {
            infoHash
        } else {
            nil
        }
    }

    /// "S2 · E5 · The Name" for an episode; `nil` for a film.
    public var episodeLine: String? {
        let number = [video.season.map { "S\($0)" }, video.episode.map { "E\($0)" }].compactMap(\.self)
        let parts = number + [video.episodeTitle].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One line saying where the download stands, for the list.
    public var statusLine: String {
        switch stage {
        case .finished:
            return ["Downloaded", bytesTotal.map(Self.size)].compactMap(\.self).joined(separator: " · ")
        case .paused:
            return ["Paused", progressText].compactMap(\.self).joined(separator: " · ")
        case .failed:
            return failure ?? "The download failed."
        case .queued:
            break
        }
        switch activity {
        case nil:
            return "Waiting for its turn"
        case .waitingForPlayer:
            return "Waiting until nothing is playing"
        case .findingPeers:
            return "Looking for people sharing this…"
        case .checking:
            return ["Checking what is already here", progressText].compactMap(\.self).joined(separator: " · ")
        case .finishing:
            return "Finishing…"
        case let .downloading(rate, peers):
            let left = bytesTotal.flatMap { ArrivalMeter.timeLeft(bytes: $0 - bytesDone, rate: rate) }
            let parts: [String?] = [
                progressText,
                "\(Self.size(Int64(rate)))/s",
                peers.map { "\($0) \($0 == 1 ? "connection" : "connections")" },
                left,
            ]
            return parts.compactMap(\.self).joined(separator: " · ")
        }
    }

    /// "1,2 GB of 4,7 GB".
    private var progressText: String? {
        guard let bytesTotal, bytesTotal > 0 else { return bytesDone > 0 ? Self.size(bytesDone) : nil }
        return "\(Self.size(bytesDone)) of \(Self.size(bytesTotal))"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

public extension DownloadItem.Source {
    /// How a stream is downloaded; `nil` for the kinds that cannot be (a YouTube video, a web
    /// page, a playlist of segments).
    init?(_ stream: StreamItem) {
        switch stream.source {
        case let .torrent(infoHash, fileIndex):
            let trackers = stream.peerSources.compactMap { $0.hasPrefix("tracker:") ? String($0.dropFirst("tracker:".count)) : nil }
            self = .torrent(infoHash: infoHash, fileIndex: fileIndex, fileName: stream.behaviorHints.filename, trackers: trackers)
        case let .url(url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !Self.isPlaylist(url) else { return nil }
            self = .direct(url: url, headers: stream.behaviorHints.requestHeaders)
        case .youTube, .external:
            return nil
        }
    }

    /// A stream cut into many small files, listed in a playlist: there is no one file to keep.
    static func isPlaylist(_ url: URL) -> Bool {
        ["m3u8", "m3u", "mpd"].contains(url.pathExtension.lowercased())
    }
}
