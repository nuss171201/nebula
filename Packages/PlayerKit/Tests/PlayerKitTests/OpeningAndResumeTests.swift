import Foundation
@testable import PlayerKit
import Testing

@Suite("Files and folders the user opens")
struct MediaFilesTests {
    /// Creates empty files with these paths under a new temporary folder.
    private func makeTree(_ paths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-files-\(UUID().uuidString)", isDirectory: true)
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        return root
    }

    @Test("Media and subtitle files are told apart by extension, whatever its case")
    func kinds() {
        #expect(MediaFiles.isPlayable(URL(fileURLWithPath: "/a/Film.MKV")))
        #expect(MediaFiles.isPlayable(URL(fileURLWithPath: "/a/song.flac")))
        #expect(!MediaFiles.isPlayable(URL(fileURLWithPath: "/a/notes.txt")))
        #expect(!MediaFiles.isPlayable(URL(fileURLWithPath: "/a/film.srt")))
        #expect(MediaFiles.isSubtitle(URL(fileURLWithPath: "/a/film.en.SRT")))
        #expect(!MediaFiles.isSubtitle(URL(fileURLWithPath: "/a/film.mkv")))
    }

    @Test("A folder gives its media in Finder's order, subfolders after files, hidden files left out")
    func folders() throws {
        let root = try makeTree([
            "Show/Episode 10.mkv", "Show/Episode 2.mkv", "Show/episode 1.mkv", "Show/Episode 2.srt", "Show/notes.txt",
            "Show/.hidden.mkv", "Show/Extras/Clip.mp4", "Show/Extras/Another Clip.mp4", "Show/Zebra.mp4",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = MediaFiles.selection(from: [root.appendingPathComponent("Show")])
        // Each path from the opened folder down, however the system spells the temporary folder.
        let names = selection.media.map { url in
            let parts = url.pathComponents
            return parts.suffix(from: (parts.lastIndex(of: "Show") ?? -1) + 1).joined(separator: "/")
        }
        #expect(names == ["episode 1.mkv", "Episode 2.mkv", "Episode 10.mkv", "Zebra.mp4", "Extras/Another Clip.mp4", "Extras/Clip.mp4"])
        // Subtitles found inside a folder are the player's business (it loads the ones that match), not the queue's.
        #expect(selection.subtitles.isEmpty)
    }

    @Test("Files given directly keep their order; subtitles are set aside; the rest is ignored")
    func files() throws {
        let root = try makeTree(["b.mp3", "a.mkv", "film.srt", "readme.txt", "Folder/x.mp4"])
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["b.mp3", "film.srt", "missing.mkv", "readme.txt", "Folder", "a.mkv"].map { root.appendingPathComponent($0) }
        let selection = MediaFiles.selection(from: urls)
        #expect(selection.media.map(\.lastPathComponent) == ["b.mp3", "x.mp4", "a.mkv"])
        #expect(selection.subtitles.map(\.lastPathComponent) == ["film.srt"])
        // Addresses that are not files are not looked at.
        #expect(MediaFiles.selection(from: [URL(string: "https://example.com/a.mkv")].compactMap(\.self)).media.isEmpty)
    }

    @Test("A huge folder is cut off at the limit")
    func limit() throws {
        let root = try makeTree((1 ... 30).map { "clip \($0).mp4" })
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MediaFiles.selection(from: [root], limit: 12).media.count == 12)
    }
}

@Suite("Where to resume (pure)")
struct ResumeLogicTests {
    @Test("The first seconds count as not started, the credits as finished, and the middle is somewhere to return to", arguments: [
        (5.0, 3600.0, ResumePoint.notStarted),
        (10.0, 3600.0, .at(10)),
        (1800.0, 3600.0, .at(1800)),
        // The last twentieth of a film is the credits.
        (3500.0, 3600.0, .finished),
        (3400.0, 3600.0, .at(3400)),
        // But never more than six minutes, however long it is.
        (13900.0, 14400.0, .at(13900)),
        (14100.0, 14400.0, .finished),
        // And at least the last ten seconds of anything.
        (85.0, 90.0, .finished),
        (79.0, 90.0, .at(79)),
        (12.0, 20.0, .finished),
    ])
    func points(position: Double, duration: Double, expected: ResumePoint) {
        #expect(ResumeState.point(for: position, duration: duration) == expected)
    }

    @Test("Without a known length, anything past the beginning is somewhere to return to")
    func liveStreams() {
        #expect(ResumeState.point(for: 500, duration: nil) == .at(500))
        #expect(ResumeState.point(for: 3, duration: nil) == .notStarted)
        #expect(ResumePoint.at(12).position == 12 && ResumePoint.finished.position == nil)
    }
}

@MainActor
@Suite("Resuming through the engine", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct ResumeEngineTests {
    private let key = "file:" + TestMedia.long.path

    private func makePlayer(memory: FakePlayerMemory, resumes: Bool = true) throws -> PlayerModel {
        try PlayerModel(
            configuration: PlayerConfiguration(
                userAgent: "PlayerKitTests/1.0",
                logSubsystem: "test.playerkit",
                videoOutput: .none,
                playsAudio: false,
                resumesPlayback: resumes
            ),
            memory: memory
        )
    }

    private func eventually(within timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test("A file opens where it was left, and says so")
    func resumes() async throws {
        let memory = FakePlayerMemory(positions: [key: 40])
        let player = try makePlayer(memory: memory)
        defer { player.shutdown() }
        try player.open(PlayableSource(url: TestMedia.long))
        #expect(await eventually { player.state.phase == .playing && abs(player.state.position - 40) < 1.5 })
        #expect(player.notice?.text == "Resumed at 0:40")
    }

    @Test("Where a file is left is remembered: on pause, as it plays, and when another file replaces it")
    func remembers() async throws {
        let memory = FakePlayerMemory()
        let player = try makePlayer(memory: memory)
        defer { player.shutdown() }
        try player.open(PlayableSource(url: TestMedia.long))
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
        await player.waitForTrackSelection()
        #expect(player.notice == nil)

        player.seek(to: 30)
        #expect(await eventually { abs(player.state.position - 30) < 1 })
        player.setPaused(true)
        #expect(await eventually { await abs((memory.positions[key] ?? 0) - 30) < 1.5 })

        // Left at another place by opening something else.
        player.seek(to: 55)
        #expect(await eventually { abs(player.state.position - 55) < 1 })
        try player.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { await abs((memory.positions[key] ?? 0) - 55) < 1.5 })
        // The short file that replaced it has nothing worth resuming.
        #expect(await eventually { player.state.phase == .playing && player.title == "sdr-h264-1080p.mp4" })
        #expect(await memory.positions["file:" + TestMedia.sdr.path] == nil)
    }

    @Test("A file watched to its end starts from the beginning next time")
    func forgetsAtTheEnd() async throws {
        let memory = FakePlayerMemory(positions: [key: 40])
        let player = try makePlayer(memory: memory)
        defer { player.shutdown() }
        try player.open(PlayableSource(url: TestMedia.long))
        #expect(await eventually { abs(player.state.position - 40) < 1.5 })
        player.seek(to: 86)
        #expect(await eventually { player.state.position > 85 })
        player.setPaused(true)
        #expect(await eventually { await memory.points[key] == .finished })
        // The length goes with it, for showing progress elsewhere.
        #expect(await abs((memory.durations[key] ?? 0) - 90) < 1)
    }

    @Test("With resuming switched off, files start at the beginning and nothing is stored")
    func switchedOff() async throws {
        let memory = FakePlayerMemory(positions: [key: 40])
        let player = try makePlayer(memory: memory, resumes: false)
        defer { player.shutdown() }
        try player.open(PlayableSource(url: TestMedia.long))
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
        await player.waitForTrackSelection()
        #expect(player.state.position < 5)
        player.seek(to: 60)
        #expect(await eventually { abs(player.state.position - 60) < 1 })
        player.setPaused(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await memory.positions[key] == 40)
    }
}

@Suite("How a source is opened")
struct PlaybackOptionsTests {
    @Test("Headers an add-on asks for become the engine's per-file option, escaped and with their length in front")
    func headers() {
        #expect(PlaybackOptions().headerOption == nil)
        let plain = PlaybackOptions(httpHeaders: ["Referer": "https://example.com/"])
        // 29 is the length in bytes of what follows the second "%".
        #expect(plain.headerOption == "http-header-fields=%29%Referer: https://example.com/")

        // Sorted by name; a comma inside a value is escaped so it does not start a new header.
        let several = PlaybackOptions(httpHeaders: ["User-Agent": "Mozilla/5.0 (KHTML, like Gecko)", "Cookie": "a=b"])
        let list = #"Cookie: a=b,User-Agent: Mozilla/5.0 (KHTML\, like Gecko)"#
        #expect(several.headerOption == "http-header-fields=%\(list.utf8.count)%\(list)")
    }

    @Test("Headers that could smuggle in another line, or have no proper name, are dropped")
    func unsafeHeaders() {
        let options = PlaybackOptions(httpHeaders: ["X-Ok": "1", "X-Bad": "1\r\nHost: evil", "": "x", "Bad Name": "x", "X:Y": "x"])
        #expect(options.headerOption == "http-header-fields=%7%X-Ok: 1")
        #expect(PlaybackOptions(httpHeaders: ["X-Bad": "a\nb"]).headerOption == nil)
    }
}
