import Foundation
@testable import MediaCore
import Testing

@Suite("Add-on resource URLs")
struct ResourcePathTests {
    @Test("Paths follow /{resource}/{type}/{id}[/{extra}].json")
    func basicPaths() {
        #expect(AddonResourcePath(resource: "meta", type: .movie, id: "tt0111161").encodedPath == "meta/movie/tt0111161.json")
        #expect(
            AddonResourcePath(resource: "stream", type: .series, id: "tt0386676:1:2").encodedPath
                == "stream/series/tt0386676%3A1%3A2.json"
        )
        #expect(
            AddonResourcePath(
                resource: "catalog",
                type: .movie,
                id: "top",
                extra: [.init("genre", "Sci-Fi"), .init("skip", "100")]
            ).encodedPath == "catalog/movie/top/genre=Sci-Fi&skip=100.json"
        )
    }

    @Test("Values are escaped like encodeURIComponent", arguments: [
        ("the office", "the%20office"),
        ("rock & roll", "rock%20%26%20roll"),
        ("a/b?c=d", "a%2Fb%3Fc%3Dd"),
        ("50%", "50%25"),
        ("café", "caf%C3%A9"),
        ("it's (ok)!", "it's%20(ok)!"),
        ("a+b", "a%2Bb"),
    ])
    func escaping(input: String, expected: String) {
        let path = AddonResourcePath(resource: "catalog", type: .movie, id: "top", extra: [.init("search", input)])
        #expect(path.encodedPath == "catalog/movie/top/search=\(expected).json")
    }

    @Test("Catalog requests add skip only when paging")
    func catalogRequest() {
        let first = CatalogRequest(type: .series, catalogID: "top", extra: [.init("genre", "Drama")])
        #expect(first.path.encodedPath == "catalog/series/top/genre=Drama.json")

        let later = CatalogRequest(type: .series, catalogID: "top", extra: [.init("genre", "Drama")], skip: 50)
        #expect(later.path.encodedPath == "catalog/series/top/genre=Drama&skip=50.json")

        #expect(CatalogRequest(type: .movie, catalogID: "top").path.encodedPath == "catalog/movie/top.json")
    }

    @Test("Resource URLs are resolved next to the manifest, keeping configuration segments and queries")
    func resourceURLs() throws {
        let path = AddonResourcePath(resource: "meta", type: .movie, id: "tt1")

        let plain = try AddonTransportURL(userInput: "https://addon.example.com/manifest.json")
        #expect(plain.resourceURL(for: path)?.absoluteString == "https://addon.example.com/meta/movie/tt1.json")

        let configured = try AddonTransportURL(userInput: "https://addon.example.com/lang%3Den%7Cq%3Dhd/manifest.json")
        #expect(
            configured.resourceURL(for: path)?.absoluteString
                == "https://addon.example.com/lang%3Den%7Cq%3Dhd/meta/movie/tt1.json"
        )

        let withQuery = try AddonTransportURL(userInput: "https://addon.example.com/manifest.json?token=abc")
        #expect(withQuery.resourceURL(for: path)?.absoluteString == "https://addon.example.com/meta/movie/tt1.json?token=abc")

        #expect(configured.configureURL?.absoluteString == "https://addon.example.com/lang%3Den%7Cq%3Dhd/configure")
    }
}
