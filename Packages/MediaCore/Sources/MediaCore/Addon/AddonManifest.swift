import Foundation

/// An add-on's self-description (`manifest.json`): what it is and which resources it serves.
public struct AddonManifest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var version: String
    public var name: String
    public var description: String?
    public var logo: URL?
    public var background: URL?
    public var types: [MediaType]
    public var resources: [ManifestResource]
    public var catalogs: [ManifestCatalog]
    /// Only ids starting with one of these are served. `nil` means "any id".
    public var idPrefixes: [String]?
    public var behaviorHints: ManifestBehaviorHints

    public init(
        id: String,
        version: String = "1.0.0",
        name: String,
        description: String? = nil,
        logo: URL? = nil,
        background: URL? = nil,
        types: [MediaType] = [],
        resources: [ManifestResource] = [],
        catalogs: [ManifestCatalog] = [],
        idPrefixes: [String]? = nil,
        behaviorHints: ManifestBehaviorHints = .init()
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.description = description
        self.logo = logo
        self.background = background
        self.types = types
        self.resources = resources
        self.catalogs = catalogs
        self.idPrefixes = idPrefixes
        self.behaviorHints = behaviorHints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.lenientString(.id), let name = container.lenientString(.name) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A manifest needs an id and a name."
            ))
        }
        self.id = id
        self.name = name
        version = container.lenientString(.version) ?? "0.0.0"
        description = container.lenientString(.description)
        logo = container.lenientWebURL(.logo)
        background = container.lenientWebURL(.background)
        types = container.lenientArray(.types)
        resources = container.lenientArray(.resources)
        catalogs = container.lenientArray(.catalogs)
        let prefixes = container.lenientStrings(.idPrefixes)
        idPrefixes = prefixes.isEmpty ? nil : prefixes
        behaviorHints = (try? container.decodeIfPresent(ManifestBehaviorHints.self, forKey: .behaviorHints)) ?? .init()
    }

    /// Whether this add-on serves `resource` for an item of the given type and id.
    public func supports(resource name: String, type: MediaType, id: String) -> Bool {
        guard let resource = resources.first(where: { $0.name == name }), (resource.types ?? types).contains(type) else { return false }
        guard let prefixes = resource.idPrefixes ?? idPrefixes else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }

    public func supports(resource name: String) -> Bool {
        resources.contains { $0.name == name }
    }
}

/// One entry of a manifest's `resources`: either a bare name or a name with its own
/// type and id-prefix restrictions.
public struct ManifestResource: Codable, Sendable, Hashable {
    public static let catalog = "catalog"
    public static let meta = "meta"
    public static let stream = "stream"
    public static let subtitles = "subtitles"

    public var name: String
    public var types: [MediaType]?
    public var idPrefixes: [String]?

    public init(name: String, types: [MediaType]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }

    public init(from decoder: any Decoder) throws {
        if let shortForm = try? decoder.singleValueContainer().decode(String.self) {
            name = shortForm
            types = nil
            idPrefixes = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        types = container.contains(.types) ? container.lenientArray(.types) : nil
        let prefixes = container.lenientStrings(.idPrefixes)
        idPrefixes = prefixes.isEmpty ? nil : prefixes
    }
}

public struct ManifestBehaviorHints: Codable, Sendable, Hashable {
    public var adult: Bool
    public var p2p: Bool
    /// The add-on has a settings page at `<base>/configure`.
    public var configurable: Bool
    /// The add-on cannot be used until the user has configured it.
    public var configurationRequired: Bool

    public init(adult: Bool = false, p2p: Bool = false, configurable: Bool = false, configurationRequired: Bool = false) {
        self.adult = adult
        self.p2p = p2p
        self.configurable = configurable
        self.configurationRequired = configurationRequired
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        adult = container.lenientBool(.adult)
        p2p = container.lenientBool(.p2p)
        configurable = container.lenientBool(.configurable)
        configurationRequired = container.lenientBool(.configurationRequired)
    }
}

/// A catalog an add-on offers, for example "Popular movies".
public struct ManifestCatalog: Codable, Sendable, Hashable {
    public static let searchExtra = "search"
    public static let skipExtra = "skip"
    public static let genreExtra = "genre"

    public var type: MediaType
    public var id: String
    public var name: String?
    /// Parameters the catalog accepts (filters, search text, paging offset).
    public var extra: [ExtraProperty]

    public init(type: MediaType, id: String, name: String? = nil, extra: [ExtraProperty] = []) {
        self.type = type
        self.id = id
        self.name = name
        self.extra = extra
    }

    private enum LegacyKeys: String, CodingKey {
        case extraSupported, extraRequired, genres
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = container.lenientString(.type), let id = container.lenientString(.id) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A catalog needs a type and an id."
            ))
        }
        self.type = MediaType(rawValue: type)
        self.id = id
        name = container.lenientString(.name)

        if container.contains(.extra) {
            extra = container.lenientArray(.extra)
        } else {
            // Older manifests list parameter names in two arrays and genre options separately.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let required = Set(legacy.lenientStrings(.extraRequired))
            let genres = legacy.lenientStrings(.genres)
            var names = legacy.lenientStrings(.extraSupported)
            names.append(contentsOf: required.filter { !names.contains($0) }.sorted())
            extra = names.map { name in
                ExtraProperty(
                    name: name,
                    isRequired: required.contains(name),
                    options: name == Self.genreExtra ? genres : []
                )
            }
        }
    }

    public var displayName: String {
        name ?? id
    }

    public func extraProperty(named name: String) -> ExtraProperty? {
        extra.first { $0.name == name }
    }

    public var requiredExtras: [ExtraProperty] {
        extra.filter(\.isRequired)
    }

    /// Can be shown on the Home board as-is: nothing has to be chosen first.
    public var isBoardEligible: Bool {
        requiredExtras.isEmpty
    }

    /// Accepts a search query and needs nothing else.
    public var isSearchable: Bool {
        extraProperty(named: Self.searchExtra) != nil
            && requiredExtras.allSatisfy { $0.name == Self.searchExtra }
    }

    /// Supports paging through the `skip` parameter.
    public var supportsPaging: Bool {
        extraProperty(named: Self.skipExtra) != nil
    }

    /// Parameters the user can choose from a list (genre, year, …).
    public var selectableExtras: [ExtraProperty] {
        extra.filter { !$0.options.isEmpty }
    }

    /// Can be browsed in Discover: every required parameter has options to pick from.
    public var isBrowsable: Bool {
        requiredExtras.allSatisfy { !$0.options.isEmpty }
    }
}

/// A parameter a catalog accepts.
public struct ExtraProperty: Codable, Sendable, Hashable {
    public var name: String
    public var isRequired: Bool
    /// The allowed values. Empty means free-form (search text, a skip offset).
    public var options: [String]
    public var optionsLimit: Int?

    public init(name: String, isRequired: Bool = false, options: [String] = [], optionsLimit: Int? = nil) {
        self.name = name
        self.isRequired = isRequired
        self.options = options
        self.optionsLimit = optionsLimit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isRequired = container.lenientBool(.isRequired)
        options = container.lenientStrings(.options)
        optionsLimit = container.lenientInt(.optionsLimit)
    }
}
