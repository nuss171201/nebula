import Foundation
import MediaCore
import os
@testable import PlayerKit
import Testing

/// A subtitle service with canned answers that records what it was asked.
private final class FakeSubtitleService: OnlineSubtitleService {
    struct State {
        var titles: Result<[SubtitleTitleMatch], OnlineSubtitleError> = .success([])
        var subtitles: Result<[OnlineSubtitle], OnlineSubtitleError> = .success([])
        var download: Result<URL, OnlineSubtitleError> = .failure(.failed("no file"))
        var titleQueries: [String] = []
        var videos: [SubtitleVideo] = []
        var hints: [SubtitleFileHints] = []
        var downloads: [String] = []
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    func titles(matching query: String) async throws(OnlineSubtitleError) -> [SubtitleTitleMatch] {
        try state.withLock { state in
            state.titleQueries.append(query)
            return state.titles
        }.get()
    }

    func subtitles(for video: SubtitleVideo, file: SubtitleFileHints) async throws(OnlineSubtitleError) -> [OnlineSubtitle] {
        try state.withLock { state in
            state.videos.append(video)
            state.hints.append(file)
            return state.subtitles
        }.get()
    }

    func download(_ subtitle: OnlineSubtitle) async throws(OnlineSubtitleError) -> URL {
        try state.withLock { state in
            state.downloads.append(subtitle.id)
            return state.download
        }.get()
    }
}

private func subtitle(_ id: String, _ language: String, release: String? = nil) -> OnlineSubtitle {
    OnlineSubtitle(
        id: id,
        url: URL(string: "https://subs.example.com/\(id)") ?? URL(fileURLWithPath: "/"),
        language: language,
        releaseName: release,
        providerName: "Test Subtitles"
    )
}

@Suite("Online subtitles (pure)")
struct OnlineSubtitleValueTests {
    @Test("Subtitles are grouped by language: the user's languages first, then the rest by name")
    func grouping() {
        let found = [
            subtitle("1", "pob"), subtitle("2", "eng"), subtitle("3", "fre"), subtitle("4", "ENG"),
            subtitle("5", "ger"), subtitle("6", "xx-unknown"),
        ]
        let groups = SubtitleLanguageGroup.groups(of: found, preferredLanguages: ["fr", "en-GB"], locale: Locale(identifier: "en"))
        #expect(groups.map(\.name) == ["French", "English", "German", "Portuguese (Brazil)", "XX-UNKNOWN"])
        // Tags that differ only in case are one language, in the provider's order.
        #expect(groups[1].subtitles.map(\.id) == ["2", "4"])
        #expect(groups.map(\.id) == ["fre", "eng", "ger", "pob", "xx-unknown"])

        // A provider's own tag counts as its language when ranking.
        let portuguese = SubtitleLanguageGroup.groups(of: found, preferredLanguages: ["pt"], locale: Locale(identifier: "en"))
        #expect(portuguese.first?.name == "Portuguese (Brazil)")
        #expect(SubtitleLanguageGroup.groups(of: [], preferredLanguages: ["en"]).isEmpty)
    }

    @Test("A film is asked for by its id, an episode by id, season and episode")
    func videoIDs() {
        let film = SubtitleTitleMatch(id: "tt0063350", type: .movie, name: "Night of the Living Dead", year: "1968")
        #expect(SubtitleVideo(title: film, season: 3, episode: 4).videoID == "tt0063350")
        #expect(film.kindName == "Film")
        let show = SubtitleTitleMatch(id: "tt0000042", type: .series, name: "Example Show")
        #expect(SubtitleVideo(title: show, season: 3, episode: 4) == SubtitleVideo(type: .series, videoID: "tt0000042:3:4"))
        #expect(show.kindName == "Series")
        #expect(SubtitleTitleMatch(id: "x", type: MediaType(rawValue: "channel"), name: "C").kindName == "Channel")
    }
}

@MainActor
@Suite("Finding subtitles online", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct OnlineSubtitlesModelTests {
    private func makePlayer() throws -> PlayerModel {
        try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .none,
            playsAudio: false
        ))
    }

    private func eventually(within timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("The file name fills in the title, season and episode; a new file starts over")
    func prepares() throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        let service = FakeSubtitleService()
        let model = OnlineSubtitlesModel(player: player, service: service, preferredLanguages: ["en"])

        try model.prepare(for: PlayableSource(userInput: "https://example.com/video/The.Example.Show.S02E05.720p.mkv"))
        #expect(model.query == "The Example Show")
        #expect(model.season == 2 && model.episode == 5)
        #expect(model.titlePhase == .idle && model.subtitlePhase == .idle)
        // Preparing does not look anything up by itself, and changing the episode before a title is chosen does not either.
        model.season = 3
        #expect(service.state.withLock { $0.titleQueries.isEmpty && $0.videos.isEmpty })

        try model.prepare(for: PlayableSource(userInput: "/films/Night of the Living Dead (1968).mp4"))
        #expect(model.query == "Night of the Living Dead")
        #expect(model.season == 1 && model.episode == 1)
    }

    @Test("Searching lists titles; choosing one finds its subtitles; changing the episode finds that episode's")
    func searchesAndChooses() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        let service = FakeSubtitleService()
        let show = SubtitleTitleMatch(id: "tt0000042", type: .series, name: "Example Show", year: "2019–2021")
        service.state.withLock { state in
            state.titles = .success([show])
            state.subtitles = .success([subtitle("a", "ger"), subtitle("b", "eng", release: "Show.S02E05.WEB")])
        }
        let model = OnlineSubtitlesModel(player: player, service: service, preferredLanguages: ["en"])
        try model.prepare(for: PlayableSource(userInput: "https://example.com/Example.Show.S02E05.mkv"))

        model.query = "   "
        model.searchTitles()
        #expect(model.titlePhase == .idle)

        model.query = " Example Show "
        model.searchTitles()
        #expect(model.titlePhase == .searching)
        await model.waitUntilIdle()
        #expect(model.titlePhase == .results([show]))
        #expect(service.state.withLock { $0.titleQueries } == ["Example Show"])

        model.choose(show)
        #expect(model.chosenTitle == show && model.subtitlePhase == .searching)
        await model.waitUntilIdle()
        guard case let .results(groups) = model.subtitlePhase else {
            Issue.record("expected results, got \(model.subtitlePhase)")
            return
        }
        #expect(groups.map(\.id) == ["eng", "ger"])
        #expect(service.state.withLock { $0.videos } == [SubtitleVideo(type: .series, videoID: "tt0000042:2:5")])
        #expect(service.state.withLock { $0.hints.last?.fileName } == "Example.Show.S02E05.mkv")

        model.episode = 6
        await model.waitUntilIdle()
        #expect(service.state.withLock { $0.videos.last } == SubtitleVideo(type: .series, videoID: "tt0000042:2:6"))

        model.clearTitle()
        #expect(model.chosenTitle == nil && model.subtitlePhase == .idle)
        // The list of titles is still there to pick another from.
        #expect(model.titlePhase == .results([show]))
    }

    @Test("Failures are shown in words and can be retried")
    func failures() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        let service = FakeSubtitleService()
        let film = SubtitleTitleMatch(id: "tt1", type: .movie, name: "Film")
        service.state.withLock { state in
            state.titles = .failure(.noProvider)
            state.subtitles = .failure(.failed("The add-on did not answer."))
        }
        let model = OnlineSubtitlesModel(player: player, service: service, preferredLanguages: [])
        model.query = "Film"
        model.searchTitles()
        await model.waitUntilIdle()
        #expect(model.titlePhase == .failed(OnlineSubtitleError.noProvider.userMessage))

        model.choose(film)
        await model.waitUntilIdle()
        #expect(model.subtitlePhase == .failed("The add-on did not answer."))

        service.state.withLock { $0.subtitles = .success([]) }
        model.findSubtitles()
        await model.waitUntilIdle()
        #expect(model.subtitlePhase == .results([]))
        // A film's subtitles do not depend on the episode fields.
        model.episode = 9
        await model.waitUntilIdle()
        #expect(service.state.withLock { $0.videos.count } == 2)
    }

    @Test("A chosen subtitle is downloaded, added to the open video and selected")
    func usesSubtitle() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        let service = FakeSubtitleService()
        let model = OnlineSubtitlesModel(player: player, service: service, preferredLanguages: ["en"])
        let source = try PlayableSource(url: TestMedia.sdr)
        player.open(source)
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
        model.prepare(for: source)
        #expect(player.state.tracks(of: .subtitle).isEmpty)

        // The download fails: said in words, nothing added.
        let english = subtitle("en1", "eng", release: "Sample.Release")
        model.use(english)
        #expect(model.downloadingID == "en1")
        await model.waitUntilIdle()
        #expect(model.downloadingID == nil && model.addedIDs.isEmpty)
        #expect(model.downloadError == "no file")

        // The download gives a file the engine cannot read.
        service.state.withLock { $0.download = .success(TestMedia.directory.appending(path: "missing.srt")) }
        model.use(english)
        await model.waitUntilIdle()
        #expect(model.downloadError == "The subtitle was downloaded but could not be read.")

        service.state.withLock { $0.download = .success(TestMedia.directory.appending(path: "external-subs.en.srt")) }
        model.use(english)
        await model.waitUntilIdle()
        #expect(model.downloadError == nil && model.addedIDs == ["en1"])
        #expect(await eventually { player.state.selectedTrack(of: .subtitle) != nil })
        let track = try #require(player.state.selectedTrack(of: .subtitle))
        #expect(track.isExternal && track.title == "Sample.Release")
        #expect(LanguageMatcher.matches(track.language, "en"))
        #expect(service.state.withLock { $0.downloads } == ["en1", "en1", "en1"])
    }
}

@MainActor
@Suite("Subtitle files", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct SubtitleFileTests {
    private func makePlayer() throws -> PlayerModel {
        try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .none,
            playsAudio: false
        ))
    }

    private func eventually(within timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("A subtitle file can be added to the open video; it is selected and shown")
    func addsFile() async throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        let file = TestMedia.directory.appending(path: "external-subs.en.srt")
        // Nothing open: nothing to add it to.
        #expect(await player.addSubtitle(fileURL: file) == false)

        try player.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
        player.subtitles.isVisible = false

        #expect(await player.addSubtitle(fileURL: file))
        #expect(await eventually { player.state.selectedTrack(of: .subtitle)?.isExternal == true })
        #expect(player.subtitles.isVisible)
        #expect(player.state.tracks(of: .subtitle).count == 1)

        #expect(await player.addSubtitle(fileURL: TestMedia.directory.appending(path: "missing.srt")) == false)
        #expect(player.notice?.text == "Could Not Read the Subtitle File")
        #expect(player.state.tracks(of: .subtitle).count == 1)
    }

    @Test("Subtitle files named after the video, beside it or in a Subs folder, load by themselves")
    func sidecars() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-\(UUID().uuidString)", isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: folder.appendingPathComponent("Subs"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let video = folder.appendingPathComponent("clip.mp4")
        let subtitles = TestMedia.directory.appending(path: "external-subs.en.srt")
        try files.copyItem(at: TestMedia.sdr, to: video)
        try files.copyItem(at: subtitles, to: folder.appendingPathComponent("clip.en.srt"))
        try files.copyItem(at: subtitles, to: folder.appendingPathComponent("Subs/clip.de.srt"))
        // Belongs to some other video: left alone.
        try files.copyItem(at: subtitles, to: folder.appendingPathComponent("other.en.srt"))

        let player = try makePlayer()
        defer { player.shutdown() }
        try player.open(PlayableSource(url: video))
        #expect(await eventually { player.state.phase == .playing && player.state.tracks(of: .subtitle).count == 2 })
        let found = player.state.tracks(of: .subtitle)
        #expect(found.allSatisfy { $0.isExternal })
        #expect(Set(found.compactMap { LanguageMatcher.canonical($0.language) }) == ["en", "de"])
    }
}
