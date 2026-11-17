import Foundation

/// The path of one add-on resource request:
/// `/{resource}/{type}/{id}.json` or `/{resource}/{type}/{id}/{extra}.json`.
public struct AddonResourcePath: Sendable, Hashable {
    /// One `name=value` parameter. Order is preserved because it is part of the URL
    /// and therefore of the cache key.
    public struct Extra: Sendable, Hashable {
        public var name: String
        public var value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public var resource: String
    public var type: MediaType
    public var id: String
    public var extra: [Extra]

    public init(resource: String, type: MediaType, id: String, extra: [Extra] = []) {
        self.resource = resource
        self.type = type
        self.id = id
        self.extra = extra
    }

    /// The percent-encoded path, relative to the add-on's base URL (no leading slash).
    public var encodedPath: String {
        var path = [resource, type.rawValue, id].map(Self.encodeComponent).joined(separator: "/")
        if !extra.isEmpty {
            let arguments = extra
                .map { Self.encodeComponent($0.name) + "=" + Self.encodeComponent($0.value) }
                .joined(separator: "&")
            path += "/" + arguments
        }
        return path + ".json"
    }

    /// Same character set as JavaScript's `encodeURIComponent`, which add-on servers
    /// expect: everything is escaped except `A–Z a–z 0–9 - _ . ! ~ * ' ( )`.
    private static let unescaped = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )

    static func encodeComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unescaped) ?? text
    }
}

public extension AddonTransportURL {
    /// The absolute URL of a resource on this add-on.
    func resourceURL(for path: AddonResourcePath) -> URL? {
        guard var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false) else { return nil }
        let manifestPath = components.percentEncodedPath
        guard let lastSlash = manifestPath.lastIndex(of: "/") else { return nil }
        components.percentEncodedPath = manifestPath[...lastSlash] + path.encodedPath
        return components.url
    }

    /// The add-on's settings page, by protocol convention at `<base>/configure`.
    var configureURL: URL? {
        guard var components = URLComponents(url: manifestURL, resolvingAgainstBaseURL: false) else { return nil }
        let manifestPath = components.percentEncodedPath
        guard let lastSlash = manifestPath.lastIndex(of: "/") else { return nil }
        components.percentEncodedPath = manifestPath[...lastSlash] + "configure"
        return components.url
    }
}

/// A request for one page of a catalog.
public struct CatalogRequest: Sendable, Hashable {
    public var type: MediaType
    public var catalogID: String
    /// Filters and search text, in the order they should appear in the URL.
    public var extra: [AddonResourcePath.Extra]
    /// Number of items to skip, for paging. `0` is omitted from the URL.
    public var skip: Int

    public init(type: MediaType, catalogID: String, extra: [AddonResourcePath.Extra] = [], skip: Int = 0) {
        self.type = type
        self.catalogID = catalogID
        self.extra = extra
        self.skip = skip
    }

    public var path: AddonResourcePath {
        var arguments = extra
        if skip > 0 {
            arguments.append(.init(ManifestCatalog.skipExtra, String(skip)))
        }
        return AddonResourcePath(resource: ManifestResource.catalog, type: type, id: catalogID, extra: arguments)
    }
}

/// One page of catalog results.
public struct CatalogPage: Sendable, Hashable {
    public var items: [MetaItem]
    /// Whether the add-on says more pages exist. `nil` when it does not say.
    public var hasMore: Bool?

    public init(items: [MetaItem], hasMore: Bool? = nil) {
        self.items = items
        self.hasMore = hasMore
    }
}
