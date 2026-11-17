import Foundation

/// The shape an add-on wants an item's artwork displayed in.
public enum PosterShape: String, Sendable, Hashable, Codable {
    case poster
    case landscape
    case square

    /// Width divided by height.
    public var aspectRatio: Double {
        switch self {
        case .poster: 2.0 / 3.0
        case .landscape: 16.0 / 9.0
        case .square: 1
        }
    }
}

/// A movie, series, channel or TV entry. Catalogs return a short form of this
/// (id, name, poster); the `meta` resource fills in the rest.
public struct MetaItem: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var type: MediaType
    public var name: String
    public var poster: URL?
    public var posterShape: PosterShape
    public var background: URL?
    public var logo: URL?
    public var description: String?
    /// Free-form release text as the add-on gives it, for example `2019` or `2005–2013`.
    public var releaseInfo: String?
    public var released: Date?
    public var imdbRating: Double?
    public var runtime: String?
    public var genres: [String]
    public var cast: [String]
    public var directors: [String]
    public var writers: [String]
    public var country: String?
    public var awards: String?
    public var trailers: [MetaTrailer]
    public var videos: [MetaVideo]
    public var links: [MetaLink]
    public var website: URL?
    /// For single-video items, the id to request streams for.
    public var defaultVideoID: String?

    public init(
        id: String,
        type: MediaType,
        name: String,
        poster: URL? = nil,
        posterShape: PosterShape = .poster,
        background: URL? = nil,
        logo: URL? = nil,
        description: String? = nil,
        releaseInfo: String? = nil,
        released: Date? = nil,
        imdbRating: Double? = nil,
        runtime: String? = nil,
        genres: [String] = [],
        cast: [String] = [],
        directors: [String] = [],
        writers: [String] = [],
        country: String? = nil,
        awards: String? = nil,
        trailers: [MetaTrailer] = [],
        videos: [MetaVideo] = [],
        links: [MetaLink] = [],
        website: URL? = nil,
        defaultVideoID: String? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.posterShape = posterShape
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.released = released
        self.imdbRating = imdbRating
        self.runtime = runtime
        self.genres = genres
        self.cast = cast
        self.directors = directors
        self.writers = writers
        self.country = country
        self.awards = awards
        self.trailers = trailers
        self.videos = videos
        self.links = links
        self.website = website
        self.defaultVideoID = defaultVideoID
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description
        case releaseInfo, released, year, imdbRating, runtime
        case genres, genre, cast, director, writer, country, awards
        case trailers, trailerStreams, videos, links, website, behaviorHints
    }

    private enum BehaviorHintKeys: String, CodingKey {
        case defaultVideoId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.lenientString(.id),
              let type = container.lenientString(.type),
              let name = container.lenientText(.name)
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A meta item needs an id, a type and a name."
            ))
        }
        self.id = id
        self.type = MediaType(rawValue: type)
        self.name = name
        poster = container.lenientWebURL(.poster)
        posterShape = container.lenientString(.posterShape).flatMap(PosterShape.init(rawValue:)) ?? .poster
        background = container.lenientWebURL(.background)
        logo = container.lenientWebURL(.logo)
        description = container.lenientText(.description)
        releaseInfo = container.lenientString(.releaseInfo) ?? container.lenientString(.year)
        released = container.lenientDate(.released)
        imdbRating = container.lenientDouble(.imdbRating)
        runtime = container.lenientString(.runtime)
        country = container.lenientString(.country)
        awards = container.lenientText(.awards)
        website = container.lenientWebURL(.website)
        links = container.lenientArray(.links)
        videos = container.lenientArray(.videos)

        // People and genres come either as plain arrays (older form) or as categorised links.
        let links = links
        func names(_ primary: CodingKeys, _ fallback: CodingKeys? = nil, linkCategory: String) -> [String] {
            let direct = container.lenientTexts(primary)
            if !direct.isEmpty {
                return direct
            }
            if let fallback {
                let legacy = container.lenientTexts(fallback)
                if !legacy.isEmpty {
                    return legacy
                }
            }
            return links.filter { $0.category.caseInsensitiveCompare(linkCategory) == .orderedSame }.map(\.name)
        }
        genres = names(.genres, .genre, linkCategory: MetaLink.genresCategory)
        cast = names(.cast, linkCategory: MetaLink.castCategory)
        directors = names(.director, linkCategory: MetaLink.directorsCategory)
        writers = names(.writer, linkCategory: MetaLink.writersCategory)

        let streams: [MetaTrailer] = container.lenientArray(.trailerStreams)
        trailers = streams.isEmpty ? container.lenientArray(.trailers) : streams

        let hints = try? container.nestedContainer(keyedBy: BehaviorHintKeys.self, forKey: .behaviorHints)
        defaultVideoID = hints?.lenientString(.defaultVideoId)
    }
}

/// A trailer hosted on YouTube.
public struct MetaTrailer: Sendable, Hashable, Decodable {
    public var youTubeID: String
    public var title: String?

    public init(youTubeID: String, title: String? = nil) {
        self.youTubeID = youTubeID
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case ytId, source, title, type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `trailerStreams` uses `ytId`; the older `trailers` uses `source` plus a `type`.
        guard let id = container.lenientString(.ytId) ?? container.lenientString(.source) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A trailer needs a YouTube id."
            ))
        }
        if let kind = container.lenientString(.type), kind.caseInsensitiveCompare("Trailer") != .orderedSame {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not a trailer: \(kind)"
            ))
        }
        youTubeID = id
        title = container.lenientString(.title)
    }
}

/// A categorised link on a detail page: a genre, a cast member, an external site.
public struct MetaLink: Sendable, Hashable, Decodable {
    public static let genresCategory = "Genres"
    public static let castCategory = "Cast"
    public static let directorsCategory = "Directors"
    public static let writersCategory = "Writers"

    public var name: String
    public var category: String
    public var url: URL?

    public init(name: String, category: String, url: URL? = nil) {
        self.name = name
        self.category = category
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case name, category, url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = container.lenientString(.name), let category = container.lenientString(.category) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A link needs a name and a category."
            ))
        }
        self.name = name
        self.category = category
        url = container.lenientURL(.url)
    }
}

/// One playable video of an item: an episode of a series, or a channel's upload.
public struct MetaVideo: Sendable, Hashable, Identifiable, Decodable {
    public var id: String
    public var title: String
    public var released: Date?
    public var season: Int?
    public var episode: Int?
    public var thumbnail: URL?
    public var overview: String?

    public init(
        id: String,
        title: String,
        released: Date? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        thumbnail: URL? = nil,
        overview: String? = nil
    ) {
        self.id = id
        self.title = title
        self.released = released
        self.season = season
        self.episode = episode
        self.thumbnail = thumbnail
        self.overview = overview
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, name, released, firstAired, season, episode, number, thumbnail, overview, description
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.lenientString(.id) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A video needs an id."
            ))
        }
        self.id = id
        season = container.lenientInt(.season)
        episode = container.lenientInt(.episode) ?? container.lenientInt(.number)
        title = container.lenientText(.title)
            ?? container.lenientText(.name)
            ?? episode.map { "Episode \($0)" }
            ?? id
        released = container.lenientDate(.released) ?? container.lenientDate(.firstAired)
        thumbnail = container.lenientWebURL(.thumbnail)
        overview = container.lenientText(.overview) ?? container.lenientText(.description)
    }
}
