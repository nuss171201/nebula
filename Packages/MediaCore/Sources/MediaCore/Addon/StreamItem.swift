import Foundation

/// A way to play a video, as offered by an add-on's `stream` resource.
public struct StreamItem: Sendable, Hashable, Decodable {
    /// Where the video comes from. Exactly one of these is present per stream.
    public enum Source: Sendable, Hashable {
        /// A direct URL the player can open.
        case url(URL)
        case youTube(id: String)
        /// A torrent, identified by its info hash, and optionally the file inside it.
        case torrent(infoHash: String, fileIndex: Int?)
        /// A web page to open outside the app.
        case external(URL)
    }

    public var source: Source
    /// Short label, typically the quality or the add-on's name for the source.
    public var name: String?
    /// Longer description: file name, size, language and so on.
    public var details: String?
    public var subtitles: [SubtitleItem]
    /// Extra peer sources for a torrent (`tracker:…`, `dht:…`).
    public var peerSources: [String]
    public var behaviorHints: StreamBehaviorHints

    public init(
        source: Source,
        name: String? = nil,
        details: String? = nil,
        subtitles: [SubtitleItem] = [],
        peerSources: [String] = [],
        behaviorHints: StreamBehaviorHints = .init()
    ) {
        self.source = source
        self.name = name
        self.details = details
        self.subtitles = subtitles
        self.peerSources = peerSources
        self.behaviorHints = behaviorHints
    }

    private enum CodingKeys: String, CodingKey {
        case url, ytId, infoHash, fileIdx, externalUrl
        case name, title, description, subtitles, sources, behaviorHints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let url = container.lenientURL(.url) {
            source = .url(url)
        } else if let youTubeID = container.lenientString(.ytId) {
            source = .youTube(id: youTubeID)
        } else if let infoHash = container.lenientString(.infoHash), Self.isInfoHash(infoHash) {
            source = .torrent(infoHash: infoHash.lowercased(), fileIndex: container.lenientInt(.fileIdx))
        } else if let external = container.lenientURL(.externalUrl) {
            source = .external(external)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A stream needs a url, ytId, infoHash or externalUrl."
            ))
        }

        name = container.lenientString(.name)
        details = container.lenientString(.description) ?? container.lenientString(.title)
        subtitles = container.lenientArray(.subtitles)
        peerSources = container.lenientStrings(.sources)
        behaviorHints = (try? container.decodeIfPresent(StreamBehaviorHints.self, forKey: .behaviorHints)) ?? .init()
    }

    /// A BitTorrent v1 info hash: 40 hexadecimal characters.
    private static func isInfoHash(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy(\.isHexDigit)
    }
}

public struct StreamBehaviorHints: Sendable, Hashable, Decodable {
    /// The stream is not an MP4 over HTTPS; it needs a real player rather than a web view.
    public var notWebReady: Bool
    /// Streams sharing a group are interchangeable across episodes; used to keep the
    /// same source when auto-playing the next episode.
    public var bingeGroup: String?
    public var filename: String?
    public var videoSize: Int64?
    public var videoHash: String?
    /// HTTP headers the player must send when requesting the stream.
    public var requestHeaders: [String: String]

    public init(
        notWebReady: Bool = false,
        bingeGroup: String? = nil,
        filename: String? = nil,
        videoSize: Int64? = nil,
        videoHash: String? = nil,
        requestHeaders: [String: String] = [:]
    ) {
        self.notWebReady = notWebReady
        self.bingeGroup = bingeGroup
        self.filename = filename
        self.videoSize = videoSize
        self.videoHash = videoHash
        self.requestHeaders = requestHeaders
    }

    private enum CodingKeys: String, CodingKey {
        case notWebReady, bingeGroup, filename, videoSize, videoHash, proxyHeaders
    }

    private enum ProxyHeaderKeys: String, CodingKey {
        case request
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notWebReady = container.lenientBool(.notWebReady)
        bingeGroup = container.lenientString(.bingeGroup)
        filename = container.lenientString(.filename)
        videoSize = container.lenientInt64(.videoSize)
        videoHash = container.lenientString(.videoHash)
        let proxy = try? container.nestedContainer(keyedBy: ProxyHeaderKeys.self, forKey: .proxyHeaders)
        requestHeaders = (try? proxy?.decodeIfPresent([String: String].self, forKey: .request)) ?? [:]
    }
}

/// A subtitle track offered by an add-on's `subtitles` resource or attached to a stream.
public struct SubtitleItem: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var url: URL
    /// Language as the add-on gives it: usually an ISO 639-2 code, sometimes a name.
    public var language: String
    /// The release or file the subtitle was made for, when the add-on says. Not part of the
    /// protocol, but common, and the best clue to whether the timing will fit.
    public var releaseName: String?

    public init(id: String, url: URL, language: String, releaseName: String? = nil) {
        self.id = id
        self.url = url
        self.language = language
        self.releaseName = releaseName
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, lang, movieReleaseName, subtitleFileName, title, label
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = container.lenientWebURL(.url) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A subtitle needs an http(s) url."
            ))
        }
        self.url = url
        language = container.lenientString(.lang) ?? "und"
        id = container.lenientString(.id) ?? url.absoluteString
        releaseName = [CodingKeys.movieReleaseName, .subtitleFileName, .title, .label].lazy
            .compactMap { container.lenientString($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
