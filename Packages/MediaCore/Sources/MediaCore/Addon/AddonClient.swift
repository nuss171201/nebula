import Foundation

/// Why an add-on request failed.
public enum AddonError: Error, Sendable, Equatable {
    case http(HTTPError)
    /// The add-on answered, but not with the JSON the protocol defines.
    case invalidResponse
    /// The add-on has nothing for this id.
    case notFound
    case invalidURL

    public var isCancellation: Bool {
        self == .http(.cancelled)
    }

    public var userMessage: String {
        switch self {
        case let .http(error): error.userMessage
        case .invalidResponse: "The add-on sent a response that could not be understood."
        case .notFound: "The add-on has no information for this title."
        case .invalidURL: "The add-on address is not valid."
        }
    }
}

/// Talks to add-ons over the open add-on protocol: `manifest.json` plus the
/// `catalog`, `meta`, `stream` and `subtitles` resources.
public struct AddonClient: Sendable {
    private let http: any HTTPClient
    private let timeout: Duration

    public init(http: any HTTPClient, timeout: Duration = .seconds(15)) {
        self.http = http
        self.timeout = timeout
    }

    public func manifest(at address: AddonTransportURL) async throws(AddonError) -> AddonManifest {
        try await fetch(address.manifestURL, as: AddonManifest.self)
    }

    public func catalog(_ request: CatalogRequest, from address: AddonTransportURL) async throws(AddonError) -> CatalogPage {
        let envelope = try await fetch(request.path, from: address, as: CatalogEnvelope.self)
        return CatalogPage(items: envelope.metas, hasMore: envelope.hasMore)
    }

    /// A catalog that answers with full metadata for several titles at once, as the
    /// "calendar" catalogs do: each title comes with its recent and upcoming videos.
    public func detailedCatalog(_ request: CatalogRequest, from address: AddonTransportURL) async throws(AddonError) -> [MetaItem] {
        try await fetch(request.path, from: address, as: DetailedCatalogEnvelope.self).metas
    }

    public func meta(type: MediaType, id: String, from address: AddonTransportURL) async throws(AddonError) -> MetaItem {
        let path = AddonResourcePath(resource: ManifestResource.meta, type: type, id: id)
        let envelope: MetaEnvelope
        do {
            envelope = try await fetch(path, from: address, as: MetaEnvelope.self)
        } catch {
            throw error == .http(.badStatus(404)) ? .notFound : error
        }
        guard let meta = envelope.meta else { throw .notFound }
        return meta
    }

    /// Streams for a video. `videoID` is the item id for movies and the episode's
    /// video id (for example `tt0386676:1:2`) for series.
    public func streams(type: MediaType, videoID: String, from address: AddonTransportURL) async throws(AddonError) -> [StreamItem] {
        let path = AddonResourcePath(resource: ManifestResource.stream, type: type, id: videoID)
        return try await fetch(path, from: address, as: StreamsEnvelope.self).streams
    }

    /// Subtitles for a video. `extra` may carry `videoHash`, `videoSize` and `filename`
    /// so the add-on can match the exact file.
    public func subtitles(
        type: MediaType,
        videoID: String,
        extra: [AddonResourcePath.Extra] = [],
        from address: AddonTransportURL
    ) async throws(AddonError) -> [SubtitleItem] {
        let path = AddonResourcePath(resource: ManifestResource.subtitles, type: type, id: videoID, extra: extra)
        return try await fetch(path, from: address, as: SubtitlesEnvelope.self).subtitles
    }

    // MARK: - Transport

    private func fetch<Body: Decodable>(
        _ path: AddonResourcePath,
        from address: AddonTransportURL,
        as type: Body.Type
    ) async throws(AddonError) -> Body {
        guard let url = address.resourceURL(for: path) else { throw .invalidURL }
        return try await fetch(url, as: type)
    }

    private func fetch<Body: Decodable>(_ url: URL, as _: Body.Type) async throws(AddonError) -> Body {
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url, timeout: timeout))
        } catch {
            throw .http(error)
        }
        do {
            return try JSONDecoder().decode(Body.self, from: response.data)
        } catch {
            throw .invalidResponse
        }
    }
}

// MARK: - Response envelopes

private struct CatalogEnvelope: Decodable {
    let metas: [MetaItem]
    let hasMore: Bool?

    private enum CodingKeys: String, CodingKey {
        case metas, hasMore
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.metas) else {
            throw DecodingError.keyNotFound(CodingKeys.metas, .init(codingPath: [], debugDescription: "No metas"))
        }
        metas = container.lenientArray(.metas)
        hasMore = try? container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }
}

/// `{"metasDetailed": […]}`; some add-ons answer the same request with plain `metas`.
private struct DetailedCatalogEnvelope: Decodable {
    let metas: [MetaItem]

    private enum CodingKeys: String, CodingKey {
        case metasDetailed, metas
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.metasDetailed) {
            metas = container.lenientArray(.metasDetailed)
        } else if container.contains(.metas) {
            metas = container.lenientArray(.metas)
        } else {
            throw DecodingError.keyNotFound(CodingKeys.metasDetailed, .init(codingPath: [], debugDescription: "No metas"))
        }
    }
}

private struct MetaEnvelope: Decodable {
    let meta: MetaItem?

    private enum CodingKeys: String, CodingKey {
        case meta
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try? container.decodeIfPresent(MetaItem.self, forKey: .meta)
    }
}

private struct StreamsEnvelope: Decodable {
    let streams: [StreamItem]

    private enum CodingKeys: String, CodingKey {
        case streams
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.streams) else {
            throw DecodingError.keyNotFound(CodingKeys.streams, .init(codingPath: [], debugDescription: "No streams"))
        }
        streams = container.lenientArray(.streams)
    }
}

private struct SubtitlesEnvelope: Decodable {
    let subtitles: [SubtitleItem]

    private enum CodingKeys: String, CodingKey {
        case subtitles
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.subtitles) else {
            throw DecodingError.keyNotFound(CodingKeys.subtitles, .init(codingPath: [], debugDescription: "No subtitles"))
        }
        subtitles = container.lenientArray(.subtitles)
    }
}
