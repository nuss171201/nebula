import AddonTestSupport
import Foundation
@testable import MediaCore
import Testing

/// End-to-end: the real `URLSession` client talking to a local mock add-on over HTTP.
@Suite("Add-on client against a mock add-on server")
struct AddonClientIntegrationTests {
    private struct Fixture {
        let server: MockAddonServer
        let address: AddonTransportURL
        let client: AddonClient
    }

    private func makeFixture(retry: RetryPolicy = .none, timeout: Duration = .seconds(5)) async throws -> Fixture {
        let server = try MockAddonServer()
        let baseURL = try await server.start()
        let http = URLSessionHTTPClient(userAgent: "Tests/1.0", retryPolicy: retry)
        return try Fixture(
            server: server,
            address: AddonTransportURL(userInput: baseURL.absoluteString),
            client: AddonClient(http: http, timeout: timeout)
        )
    }

    @Test("Fetches and parses the manifest")
    func manifest() async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(to: "/manifest.json", with: .json(AddonFixtures.manifestJSON()))

        let manifest = try await fixture.client.manifest(at: fixture.address)
        #expect(manifest.name == "Test Catalog")
        #expect(manifest.catalogs.count == 4)
    }

    @Test("Fetches catalog pages with filters and paging in the URL")
    func catalogPaging() async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(
            to: "/catalog/movie/top/genre=Sci-Fi.json",
            with: .json(AddonFixtures.catalogJSON(count: 3, hasMore: true))
        )
        fixture.server.respond(
            to: "/catalog/movie/top/genre=Sci-Fi&skip=3.json",
            with: .json(AddonFixtures.catalogJSON(count: 2, offset: 3))
        )

        let filter = [AddonResourcePath.Extra("genre", "Sci-Fi")]
        let first = try await fixture.client.catalog(
            CatalogRequest(type: .movie, catalogID: "top", extra: filter),
            from: fixture.address
        )
        #expect(first.items.map(\.name) == ["Title 1", "Title 2", "Title 3"])
        #expect(first.hasMore == true)

        let second = try await fixture.client.catalog(
            CatalogRequest(type: .movie, catalogID: "top", extra: filter, skip: 3),
            from: fixture.address
        )
        #expect(second.items.map(\.name) == ["Title 4", "Title 5"])
        #expect(second.hasMore == nil)
    }

    @Test("Search text is escaped in the request path")
    func search() async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(
            to: "/catalog/series/top/search=the%20office.json",
            with: .json(AddonFixtures.catalogJSON(type: "series", titlePrefix: "Office", count: 1))
        )
        let page = try await fixture.client.catalog(
            CatalogRequest(type: .series, catalogID: "top", extra: [.init("search", "the office")]),
            from: fixture.address
        )
        #expect(page.items.first?.name == "Office 1")
        #expect(page.items.first?.type == .series)
    }

    @Test("Malformed catalog entries are skipped, not fatal")
    func lossyCatalog() async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(to: "/catalog/movie/top.json", with: .json("""
        {"metas": [{"id": "tt1", "type": "movie", "name": "Good"}, {"name": "no id"}, 42,
                   {"id": "tt2", "type": "movie", "name": "Also good"}]}
        """))
        let page = try await fixture.client.catalog(CatalogRequest(type: .movie, catalogID: "top"), from: fixture.address)
        #expect(page.items.map(\.id) == ["tt1", "tt2"])
    }

    @Test("Fetches full metadata")
    func meta() async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(to: "/meta/series/tt0000042.json", with: .json(AddonFixtures.seriesMetaJSON()))
        let meta = try await fixture.client.meta(type: .series, id: "tt0000042", from: fixture.address)
        #expect(meta.videos.count == 4)
    }

    @Test("A missing title is reported as not found", arguments: [
        MockAddonServer.Response.status(404),
        .json(#"{"meta": null}"#),
        .json("{}"),
    ])
    func metaNotFound(response: MockAddonServer.Response) async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(to: "/meta/movie/tt9.json", with: response)
        await #expect(throws: AddonError.notFound) {
            try await fixture.client.meta(type: .movie, id: "tt9", from: fixture.address)
        }
    }

    @Test("Fetches streams and subtitles")
    func streamsAndSubtitles() async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(to: "/stream/series/tt0000042%3A1%3A2.json", with: .json("""
        {"streams": [{"url": "https://cdn.example.com/e2.mkv", "name": "720p"}, {"broken": true}]}
        """))
        fixture.server.respond(to: "/subtitles/movie/tt1/videoSize=1000&filename=a%20b.mkv.json", with: .json("""
        {"subtitles": [{"id": "1", "url": "https://subs.example.com/1.srt", "lang": "eng"}]}
        """))

        let streams = try await fixture.client.streams(type: .series, videoID: "tt0000042:1:2", from: fixture.address)
        #expect(streams.count == 1)
        #expect(streams.first?.name == "720p")

        let subtitles = try await fixture.client.subtitles(
            type: .movie,
            videoID: "tt1",
            extra: [.init("videoSize", "1000"), .init("filename", "a b.mkv")],
            from: fixture.address
        )
        #expect(subtitles.map(\.language) == ["eng"])
    }

    @Test("A response that is not protocol JSON is an invalid response", arguments: [
        "<html>Not JSON</html>",
        #"{"unexpected": []}"#,
    ])
    func invalidResponse(body: String) async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(to: "/catalog/movie/top.json", with: .json(body))
        await #expect(throws: AddonError.invalidResponse) {
            try await fixture.client.catalog(CatalogRequest(type: .movie, catalogID: "top"), from: fixture.address)
        }
    }

    @Test("Recovers from a temporary server error by retrying")
    func retriesServerErrors() async throws {
        let quickRetry = RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(10), maxDelay: .milliseconds(50), jitter: 0)
        let fixture = try await makeFixture(retry: quickRetry)
        fixture.server.respond(
            to: "/catalog/movie/top.json",
            with: .status(503), .status(503), .json(AddonFixtures.catalogJSON(count: 1))
        )
        let page = try await fixture.client.catalog(CatalogRequest(type: .movie, catalogID: "top"), from: fixture.address)
        #expect(page.items.count == 1)
        #expect(fixture.server.requestCount(for: "/catalog/movie/top.json") == 3)
    }

    @Test("A server error that persists is surfaced with its status")
    func persistentServerError() async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(to: "/catalog/movie/top.json", with: .status(500))
        await #expect(throws: AddonError.http(.badStatus(500))) {
            try await fixture.client.catalog(CatalogRequest(type: .movie, catalogID: "top"), from: fixture.address)
        }
    }

    @Test("A slow server times out")
    func timeout() async throws {
        let fixture = try await makeFixture(timeout: .milliseconds(300))
        fixture.server.respond(
            to: "/manifest.json",
            with: .json(AddonFixtures.manifestJSON(), delay: .seconds(3))
        )
        await #expect(throws: AddonError.http(.timedOut)) {
            try await fixture.client.manifest(at: fixture.address)
        }
    }

    @Test("Cancelling the task cancels the request")
    func cancellation() async throws {
        let fixture = try await makeFixture()
        fixture.server.respond(
            to: "/manifest.json",
            with: .json(AddonFixtures.manifestJSON(), delay: .seconds(3))
        )
        let task = Task {
            try await fixture.client.manifest(at: fixture.address)
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        let result = await task.result
        #expect(throws: AddonError.http(.cancelled)) {
            try result.get()
        }
    }

    @Test("An unreachable server is reported as such")
    func unreachable() async throws {
        let fixture = try await makeFixture()
        fixture.server.stop()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: AddonError.http(.cannotReachServer)) {
            try await fixture.client.manifest(at: fixture.address)
        }
    }
}
