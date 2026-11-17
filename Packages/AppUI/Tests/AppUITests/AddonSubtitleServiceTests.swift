import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import PlayerKit
import Testing

@MainActor
@Suite("Subtitles from installed add-ons")
struct AddonSubtitleServiceTests {
    private static let subtitleManifest = """
    {"id": "test.subs", "version": "1.0.0", "name": "Test Subtitles", "resources": ["subtitles"],
     "types": ["movie", "series"], "idPrefixes": ["tt"], "catalogs": []}
    """

    private struct Fixture {
        let harness: AddonHarness
        let service: AddonSubtitleService
        let directory: URL
    }

    /// A catalog add-on at the root and a subtitle add-on under `/subs/`, both installed.
    private func makeFixture(installSubtitles: Bool = true, installCatalog: Bool = true) async throws -> Fixture {
        let harness = try await AddonHarness.make()
        harness.server.respond(to: "/subs/manifest.json", with: .json(Self.subtitleManifest))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("subs-\(UUID().uuidString)", isDirectory: true)
        let service = AddonSubtitleService(
            client: harness.client,
            http: URLSessionHTTPClient(userAgent: "Tests/1.0", retryPolicy: .none),
            directory: directory
        )
        var addons: [InstalledAddon] = []
        if installCatalog {
            try await addons.append(harness.installedAddon())
        }
        if installSubtitles {
            let address = try harness.address("subs")
            try await addons.append(InstalledAddon(address: address, manifest: harness.client.manifest(at: address)))
        }
        service.update(addons: addons)
        return Fixture(harness: harness, service: service, directory: directory)
    }

    @Test("Titles come from every searchable catalog, exact names first, without duplicates")
    func findsTitles() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        fixture.harness.server.respond(to: "/catalog/movie/top/search=Title%202.json", with: .json(AddonFixtures.catalogJSON(count: 3)))
        fixture.harness.server.respond(
            to: "/catalog/series/top/search=Title%202.json",
            with: .json(AddonFixtures.catalogJSON(type: "series", titlePrefix: "Show", count: 1, offset: 10))
        )

        let titles = try await fixture.service.titles(matching: "Title 2")
        #expect(titles.map(\.name) == ["Title 2", "Title 1", "Title 3", "Show 11"])
        #expect(titles[0] == SubtitleTitleMatch(id: "tt0000002", type: .movie, name: "Title 2", year: "2002"))
        #expect(titles[3].type == .series)
    }

    @Test("One catalog failing does not hide the others; all failing is an error")
    func titleFailures() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        fixture.harness.server.respond(to: "/catalog/movie/top/search=x.json", with: .status(500))
        fixture.harness.server.respond(
            to: "/catalog/series/top/search=x.json",
            with: .json(AddonFixtures.catalogJSON(type: "series", titlePrefix: "Show", count: 1))
        )
        #expect(try await fixture.service.titles(matching: "x").map(\.name) == ["Show 1"])

        fixture.harness.server.respond(to: "/catalog/series/top/search=x.json", with: .status(500))
        await #expect(throws: OnlineSubtitleError.self) {
            try await fixture.service.titles(matching: "x")
        }
    }

    @Test("Without a searchable catalog or a subtitle add-on there is nobody to ask")
    func noProviders() async throws {
        let fixture = try await makeFixture(installSubtitles: false, installCatalog: false)
        defer { fixture.harness.server.stop() }
        await #expect(throws: OnlineSubtitleError.noProvider) {
            try await fixture.service.titles(matching: "anything")
        }
        await #expect(throws: OnlineSubtitleError.noProvider) {
            try await fixture.service.subtitles(for: SubtitleVideo(type: .movie, videoID: "tt1"), file: SubtitleFileHints())
        }
        // An add-on that only serves "tt" ids is not asked about anything else.
        let withSubtitles = try await makeFixture()
        defer { withSubtitles.harness.server.stop() }
        await #expect(throws: OnlineSubtitleError.noProvider) {
            try await withSubtitles.service.subtitles(for: SubtitleVideo(type: .movie, videoID: "kitsu:1"), file: SubtitleFileHints())
        }
    }

    @Test("Subtitles are asked for with what is known about the file, and carry their provider")
    func findsSubtitles() async throws {
        let fixture = try await makeFixture()
        defer { fixture.harness.server.stop() }
        fixture.harness.server.respond(
            to: "/subs/subtitles/series/tt0000042%3A2%3A5/videoHash=00000000000000ff&videoSize=1234&filename=Show%20S02E05.mkv.json",
            with: .json("""
            {"subtitles": [
              {"id": "1", "url": "https://subs.example.com/1.srt", "lang": "eng", "movieReleaseName": "Show.S02E05.WEB"},
              {"id": "2", "url": "https://subs.example.com/2", "lang": "pob"},
              {"id": "bad", "url": "file:///etc/passwd", "lang": "eng"}
            ]}
            """)
        )
        let title = SubtitleTitleMatch(id: "tt0000042", type: .series, name: "Example Show")
        let found = try await fixture.service.subtitles(
            for: SubtitleVideo(title: title, season: 2, episode: 5),
            file: SubtitleFileHints(fileName: "Show S02E05.mkv", fingerprint: .init(hash: "00000000000000ff", size: 1234))
        )
        #expect(found.map(\.language) == ["eng", "pob"])
        #expect(found[0].releaseName == "Show.S02E05.WEB")
        #expect(found[0].providerName == "Test Subtitles")
        #expect(found[0].id != found[1].id)

        // Nothing known about the file: the plain path is used.
        fixture.harness.server.respond(to: "/subs/subtitles/movie/tt0000001.json", with: .json(#"{"subtitles": []}"#))
        let none = try await fixture.service.subtitles(for: SubtitleVideo(type: .movie, videoID: "tt0000001"), file: SubtitleFileHints())
        #expect(none.isEmpty)
    }

    @Test("A subtitle is downloaded once and kept; bad downloads are refused")
    func downloads() async throws {
        let fixture = try await makeFixture()
        defer {
            fixture.harness.server.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let text = "1\n00:00:01,000 --> 00:00:02,000\nHello\n"
        fixture.harness.server.respond(to: "/files/one.vtt", with: .init(body: Data(text.utf8), contentType: "text/plain"))
        fixture.harness.server.respond(to: "/files/two", with: .init(body: Data(text.utf8), contentType: "text/plain"))
        fixture.harness.server.respond(to: "/files/empty", with: .init(body: Data(), contentType: "text/plain"))
        fixture.harness.server.respond(to: "/files/gone", with: .status(404))
        func subtitle(_ path: String) -> OnlineSubtitle {
            OnlineSubtitle(id: path, url: fixture.harness.baseURL.appending(path: path), language: "eng", providerName: "Test")
        }

        let first = try await fixture.service.download(subtitle("files/one.vtt"))
        #expect(first.pathExtension == "vtt")
        #expect(first.deletingLastPathComponent().path == fixture.directory.path)
        #expect(try String(contentsOf: first, encoding: .utf8) == text)
        // The second time it comes from the folder, not the network.
        #expect(try await fixture.service.download(subtitle("files/one.vtt")) == first)
        #expect(fixture.harness.server.requestCount(for: "/files/one.vtt") == 1)

        // No recognisable extension in the address: saved as .srt (the player reads the contents anyway).
        #expect(try await fixture.service.download(subtitle("files/two")).pathExtension == "srt")

        await #expect(throws: OnlineSubtitleError.self) {
            try await fixture.service.download(subtitle("files/empty"))
        }
        await #expect(throws: OnlineSubtitleError.self) {
            try await fixture.service.download(subtitle("files/gone"))
        }
    }
}

/// Opt-in check against the two real default add-ons, to catch protocol drift. Only lists
/// what is on offer for a public-domain film; no subtitle file is downloaded.
///
///     LIVE_ADDON_TESTS=1 swift test --filter LiveSubtitleServiceTests
@Suite(
    "Live subtitle lookup through the default add-ons",
    .enabled(if: ProcessInfo.processInfo.environment["LIVE_ADDON_TESTS"] == "1")
)
struct LiveSubtitleServiceTests {
    @Test("A film is found by name and has subtitles in several languages")
    func lookup() async throws {
        let http = URLSessionHTTPClient(userAgent: "AppUITests/1.0")
        let client = AddonClient(http: http)
        let service = AddonSubtitleService(client: client, http: http, directory: FileManager.default.temporaryDirectory)
        var addons: [InstalledAddon] = []
        for address in ["https://v3-cinemeta.strem.io/manifest.json", "https://opensubtitles-v3.strem.io/manifest.json"] {
            let address = try AddonTransportURL(userInput: address)
            try await addons.append(InstalledAddon(address: address, manifest: client.manifest(at: address)))
        }
        service.update(addons: addons)

        let titles = try await service.titles(matching: "Night of the Living Dead")
        let film = try #require(titles.first { $0.id == "tt0063350" })
        #expect(film.type == .movie && film.year == "1968")

        let found = try await service.subtitles(
            for: SubtitleVideo(title: film, season: 1, episode: 1),
            file: SubtitleFileHints(fileName: "Night of the Living Dead (1968).mp4")
        )
        let groups = SubtitleLanguageGroup.groups(of: found, preferredLanguages: ["en"], locale: Locale(identifier: "en"))
        #expect(groups.first?.name == "English")
        #expect(groups.count > 3)
        #expect(found.allSatisfy { $0.url.scheme == "https" || $0.url.scheme == "http" })
    }
}
