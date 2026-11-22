@testable import AppUI
import Foundation
import MediaCore
import Testing

@Suite("What a stream's description says")
struct StreamFactsTests {
    @Test("People sharing are read after a person sign or the word", arguments: [
        ("👤 15 💾 91.02 GB ⚙️ Source", 15), ("Film 1080p\n👥 207", 207), ("Seeders: 34 | Size 2 GB", 34),
        ("seeds 9", 9), ("SEEDER=1200", 1200), ("🌱3", 3),
    ])
    func peers(text: String, expected: Int) {
        #expect(StreamFacts(text: text).peers == expected)
    }

    @Test("Text that does not say how many share it leaves the number unknown", arguments: [
        "Film.2026.1080p.WEB", "S01E05 720p", "15 GB", "",
    ])
    func noPeers(text: String) {
        #expect(StreamFacts(text: text).peers == nil)
    }

    @Test("Languages come from flags, from release words and from the script; MULTi and DUAL mean several")
    func languages() {
        #expect(StreamFacts(text: "Film 1080p\n🇬🇧 / 🇷🇺").languages == ["en", "ru"])
        #expect(StreamFacts(text: "Film.Del.Mundo.2025.1080P-Remux-Lat\n🇲🇽").languages == ["es"])
        #expect(StreamFacts(text: "Film.2026.German.DL.1080p").languages == ["de"])
        #expect(StreamFacts(text: "Film.2026.TRUEFRENCH.1080p").languages == ["fr"])
        #expect(StreamFacts(text: "Проект «Конец света» / Film (2026) WEBRip 1080p").languages == ["ru"])
        #expect(StreamFacts(text: "Film.2026.1080p.WEB.H264-GRP").languages.isEmpty)
        // Not every word that contains a language's letters names it.
        #expect(StreamFacts(text: "Latitude.2026.Engine.Rust.1080p").languages.isEmpty)

        let multi = StreamFacts(text: "Film.2026.2160p.Remux.MULTi.TrueHD\nMulti Audio / 🇬🇧 / 🇯🇵 / 🇩🇪")
        #expect(multi.isMultiLanguage)
        #expect(multi.languages == ["en", "ja", "de"])
        #expect(StreamFacts(text: "Film.2026.DUAL.1080p").isMultiLanguage)
        #expect(!StreamFacts(text: "Multiverse.2026.1080p").isMultiLanguage)
    }

    @Test("Entries that are not one playable film are recognised", arguments: [
        ("Film.2026.2160p.COMPLETE.UHD.BLURAY-GRP", StreamFacts.Trap.discImage), ("Film 2026 Full BluRay BD50", .discImage),
        ("Film.2026.BDMV", .discImage), ("Film.2026.DVD9.PAL", .discImage), ("Film.2026.ISO", .discImage),
        ("Film.2026.HDCAM.x264", .cinemaRecording), ("Film 2026 TELESYNC 720p", .cinemaRecording), ("Film.2026.CAM", .cinemaRecording),
        ("Film.2026.3D.HSBS.1080p", .stereoscopic), ("film-sample.mkv", .sample),
    ])
    func traps(text: String, expected: StreamFacts.Trap) {
        #expect(StreamFacts(text: text).trap == expected)
    }

    @Test("Ordinary releases are not mistaken for them", arguments: [
        "Film.2026.1080p.BluRay.REMUX.AVC-GRP", "Film.2026.2160p.UHD.BluRay.x265", "Film.2026.DVDRip.x264", "The.Complete.Story.2026.1080p.WEB",
        "Camera.Obscura.2026.1080p", "Film.2026.1080p.WEB.DL.AAC2.0.H264", "Isolation.2026.720p", "film.2026.720p.ts",
    ])
    func noTrap(text: String) {
        #expect(StreamFacts(text: text).trap == nil)
    }

    @Test("Running times are read as catalogs write them", arguments: [
        ("156 min", 9360.0), ("2h 36min", 9360.0), ("1 h 5 m", 3900.0), ("45", 2700.0), ("90 minutes", 5400.0), ("2 hours", 7200.0),
    ])
    func runtime(text: String, seconds: Double) {
        #expect(RuntimeText.seconds(in: text) == seconds)
    }

    @Test("A running time that cannot be read is unknown", arguments: ["", "N/A", "soon", "0 min"])
    func noRuntime(text: String) {
        #expect(RuntimeText.seconds(in: text) == nil)
        #expect(RuntimeText.seconds(in: nil) == nil)
    }
}

@Suite("Choosing the stream to play")
struct StreamPickerTests {
    private static let gigabyte: Int64 = 1_073_741_824
    /// A film of two hours and thirty-six minutes.
    private let runtime: Double = 9360

    private func torrent(_ name: String, _ details: String, position: Int, addon: String = "test.streams") -> StreamChoice {
        let hash = String(repeating: String(position % 10), count: 40)
        return StreamChoice(
            stream: StreamItem(source: .torrent(infoHash: hash, fileIndex: nil), name: name, details: details),
            addonID: addon, addonName: "Test Streams", position: position
        )
    }

    /// A list like the ones add-ons really send: big disc copies first, then smaller releases,
    /// some dubbed, one that is not a film file at all.
    private var list: [StreamChoice] {
        [
            torrent("Streams 4k", "Example.Film.2026.2160p.COMPLETE.UHD.BLURAY-GRP\n👤 15 💾 91.02 GB ⚙️ A", position: 0),
            torrent("Streams 4k DV | HDR", "Example.Film.2026.2160p.UHD.BluRay.Remux.DV.HDR.MULTi.TrueHD\n👤 473 💾 80.43 GB\nMulti Audio / 🇬🇧 / 🇩🇪", position: 1),
            torrent("Streams 4k", "Example.Film.2026.2160p.WEB.H265-GRP\n👤 120 💾 14.2 GB", position: 2),
            torrent("Streams 1080p", "Example.Film.2026.1080p.BluRay.REMUX.AVC-GRP\n👤 2 💾 34.74 GB\n🇬🇧 / 🇯🇵", position: 3),
            torrent("Streams 1080p", "Проект / Example Film (2026) WEBRip 1080p\n👤 207 💾 6.5 GB\n🇷🇺", position: 4),
            torrent("Streams 1080p", "Example.Film.2026.1080p.WEB.DL.AAC2.0.H264-GRP\n👤 30 💾 8.68 GB", position: 5),
            torrent("Streams 1080p", "Example.Film.2026.1080p.WEB.x265-GRP\n👤 3 💾 3.1 GB", position: 6),
            torrent("Streams 720p", "Example.Film.2026.720p.WEB.H264-GRP\n👤 55 💾 2.2 GB", position: 7),
            torrent("Streams", "Example.Film.2026.HDCAM.x264\n👤 900 💾 1.4 GB", position: 8),
        ]
    }

    private func context(speed megabits: Double?, languages: [String] = ["en"]) -> StreamPicker.Context {
        StreamPicker.Context(runtime: runtime, measuredSpeed: megabits.map { $0 * 125_000 }, languages: languages)
    }

    @Test("What a stream needs is its size over the running time, or a usual figure for its quality")
    func requiredSpeed() throws {
        let heavy = try #require(StreamPicker.requiredSpeed(of: list[1], runtime: runtime))
        // 80.43 GB in 156 minutes is about 74 Mbit/s.
        #expect(abs(heavy * 8 / 1_000_000 - 73.8) < 0.5)
        let unsized = try StreamChoice(
            stream: StreamItem(source: .url(#require(URL(string: "https://media.example.com/film.mp4"))), name: "1080p"),
            addonID: "a", addonName: "A", position: 0
        )
        #expect(StreamPicker.requiredSpeed(of: unsized, runtime: runtime) == 1_000_000)
        let unknown = try StreamChoice(
            stream: StreamItem(source: .url(#require(URL(string: "https://media.example.com/film"))), name: "Watch"),
            addonID: "a", addonName: "A", position: 0
        )
        #expect(StreamPicker.requiredSpeed(of: unknown, runtime: runtime) == nil)
    }

    @Test("On an ordinary connection: the best quality of a modest size, in the right language, that people are sharing")
    func ordinaryConnection() {
        let picks = StreamPicker.picks(from: list, context: context(speed: 50))
        // The disc copy and the cinema recording are not offered at all.
        #expect(picks.count == 7)
        #expect(!picks.contains { $0.choice.id == "test.streams#0" || $0.choice.id == "test.streams#8" })
        // The well-shared full-HD release needs 8 Mbit/s: it is the pick. Then 720p.
        #expect(picks[0].choice.id == "test.streams#5")
        #expect(picks[0].standing == .good)
        #expect(picks[0].summary.hasPrefix("1080p · ") && picks[0].summary.hasSuffix(" GB · 30 sharing"))
        #expect(picks[1].choice.id == "test.streams#7")
        // 4K at 14.2 GB needs 13 Mbit/s. The connection has that to spare, but it is more than
        // Play takes by itself: it comes after everything of a modest size that should just play.
        #expect(picks[2].choice.id == "test.streams#2")
        #expect(picks.map(\.standing) == [.good, .good, .large, .fewPeers, .fewPeers, .tooHeavy, .wrongLanguage])
        // Then the ones only two or three people share, the small one before the 35 GB one.
        #expect(picks[3].choice.id == "test.streams#6")
        #expect(picks[4].choice.id == "test.streams#3")
        // The 80 GB disc copy needs 74 Mbit/s: more than this connection has to spare.
        #expect(picks[5].choice.id == "test.streams#1")
        // The Russian dub is last however many share it.
        #expect(picks[6].choice.id == "test.streams#4")
    }

    @Test("On a slow connection the pick is smaller; on a fast one it is still of a modest size")
    func speedDecides() {
        #expect(StreamPicker.picks(from: list, context: context(speed: 6))[0].choice.id == "test.streams#7")
        #expect(StreamPicker.picks(from: list, context: context(speed: 12))[0].choice.id == "test.streams#5")
        // However fast: the 80 GB disc copy would play, and would take minutes to start.
        let fast = StreamPicker.picks(from: list, context: context(speed: 200))
        #expect(fast[0].choice.id == "test.streams#5")
        #expect(fast.first { $0.choice.id == "test.streams#1" }?.standing == .large)
        // Nothing measured yet: 20 Mbit/s is assumed, which the disc copy does not fit.
        let unmeasured = StreamPicker.picks(from: list, context: context(speed: nil))
        #expect(unmeasured[0].choice.id == "test.streams#5")
        #expect(unmeasured.first { $0.choice.id == "test.streams#1" }?.standing == .tooHeavy)
    }

    @Test("When nothing of a modest size is well shared, the smallest of the large ones is the pick")
    func onlyLargeOnes() {
        let large = [list[1], list[2], list[6]]
        let picks = StreamPicker.picks(from: large, context: context(speed: 200))
        #expect(picks.map(\.choice.id) == ["test.streams#2", "test.streams#1", "test.streams#6"])
        #expect(picks.map(\.standing) == [.large, .large, .fewPeers])
        // A stream whose size is not given is judged by what its quality usually takes.
        let unsized = torrent("Streams 4k", "Example.Film.2026.2160p.WEB\n👤 80", position: 9)
        #expect(StreamPicker.picks(from: [unsized], context: context(speed: 200))[0].standing == .large)
        let fullHD = torrent("Streams 1080p", "Example.Film.2026.1080p.WEB\n👤 80", position: 9)
        #expect(StreamPicker.picks(from: [fullHD], context: context(speed: 200))[0].standing == .good)
    }

    @Test("Well shared comes before better looking, and of two alike the one more people share")
    func sharing() {
        let streams = [
            torrent("Streams 4k", "Example.Film.2026.2160p.WEB.H265-GRP\n👤 8 💾 7.5 GB", position: 0),
            torrent("Streams 1080p", "Example.Film.2026.1080p.WEB.H264-ONE\n👤 40 💾 6.1 GB", position: 1),
            torrent("Streams 1080p", "Example.Film.2026.1080p.WEB.H264-TWO\n👤 400 💾 4.3 GB", position: 2),
            torrent("Streams 720p", "Example.Film.2026.720p.WEB.H264-GRP\n👤 2000 💾 1.9 GB", position: 3),
        ]
        let picks = StreamPicker.picks(from: streams, context: context(speed: 100))
        #expect(picks.allSatisfy { $0.standing == .good })
        // The 4K one only eight people share waits behind everything twenty or more do; among
        // those the better picture still wins, and of the two full-HD ones the better shared.
        #expect(picks.map(\.choice.id) == ["test.streams#2", "test.streams#1", "test.streams#3", "test.streams#0"])
    }

    @Test("When nothing fits, the least demanding stream in the right language is the pick")
    func nothingFits() {
        let picks = StreamPicker.picks(from: list, context: context(speed: 1))
        #expect(picks[0].standing == .tooHeavy)
        #expect(picks[0].choice.id == "test.streams#7")
        #expect(picks.last?.standing == .wrongLanguage)
    }

    @Test("The languages asked for decide what counts as the right language")
    func languages() {
        let russian = StreamPicker.picks(from: list, context: context(speed: 50, languages: ["ru"]))
        // Streams that name no language are taken on trust; the one that names Russian is now fine too.
        #expect(russian.first { $0.choice.id == "test.streams#4" }?.standing == .good)
        // The one that names English and Japanese only is not.
        #expect(russian.first { $0.choice.id == "test.streams#3" }?.standing == .wrongLanguage)
        // A stream that says it carries several languages is never ruled out for language.
        let japanese = StreamPicker.picks(from: list, context: context(speed: 500, languages: ["ko"]))
        #expect(japanese.first { $0.choice.id == "test.streams#1" }?.standing == .large)
        // With no language asked for, none is wrong.
        #expect(!StreamPicker.picks(from: list, context: context(speed: 50, languages: [])).contains { $0.standing == .wrongLanguage })
    }

    @Test("The user's limits on quality and size are kept")
    func limits() {
        var limited = context(speed: 500)
        limited.maximumQuality = .hd1080
        let byQuality = StreamPicker.picks(from: list, context: limited)
        #expect(byQuality[0].choice.quality == .hd1080)
        #expect(byQuality[0].choice.id == "test.streams#5")
        #expect(byQuality.filter { $0.choice.quality == .uhd4K }.allSatisfy { $0.standing == .overLimit })

        limited.maximumQuality = nil
        limited.maximumSize = 5 * Self.gigabyte
        let bySize = StreamPicker.picks(from: list, context: limited)
        #expect(bySize[0].choice.id == "test.streams#7")
        #expect(bySize.first { $0.choice.id == "test.streams#2" }?.standing == .overLimit)
    }

    @Test("What was played last time comes first, as long as it is as suitable as anything")
    func likeLastTime() {
        var remembered = context(speed: 50)
        remembered.lastChoice = LastStreamChoice(list[7])
        #expect(StreamPicker.picks(from: list, context: remembered)[0].choice.id == "test.streams#7")
        // Not if it would no longer play well: last time's 4K remux on today's slow connection.
        var heavy = context(speed: 12)
        heavy.lastChoice = LastStreamChoice(list[1])
        #expect(StreamPicker.picks(from: list, context: heavy)[0].choice.id == "test.streams#5")
    }

    @Test("Web streams are picked like any other; pages and videos elsewhere are not")
    func kinds() throws {
        let web = try StreamChoice(
            stream: StreamItem(source: .url(#require(URL(string: "https://media.example.com/film.mp4"))), name: "Web 1080p"),
            addonID: "web", addonName: "Web", position: 0
        )
        let page = try StreamChoice(
            stream: StreamItem(source: .external(#require(URL(string: "https://example.com/watch"))), name: "Watch on the site 1080p"),
            addonID: "web", addonName: "Web", position: 1
        )
        let trailer = StreamChoice(stream: StreamItem(source: .youTube(id: "abcdefghijk"), name: "Trailer"), addonID: "web", addonName: "Web", position: 2)
        let picks = StreamPicker.picks(from: [page, trailer, web], context: context(speed: 50))
        #expect(picks.map(\.choice.id) == ["web#0"])
        #expect(picks[0].summary == "1080p")
        #expect(StreamPicker.picks(from: [], context: context(speed: 50)).isEmpty)
    }

    @Test("The connection's speed is learned from what streams achieve: up at once, down slowly")
    func connectionSpeed() {
        #expect(ConnectionSpeed.updated(nil, sessionBest: 4_000_000) == 4_000_000)
        #expect(ConnectionSpeed.updated(4_000_000, sessionBest: 9_000_000) == 9_000_000)
        #expect(ConnectionSpeed.updated(4_000_000, sessionBest: 1_000_000) == 3_600_000)
        #expect(ConnectionSpeed.updated(4_000_000, sessionBest: 0) == 4_000_000)
        #expect(ConnectionSpeed.updated(nil, sessionBest: 0) == nil)

        // A burst does not count; five readings in a row do.
        #expect(ConnectionSpeed.bestSustained([0, 0, 90, 0, 0, 0]) == 18)
        #expect(ConnectionSpeed.bestSustained([10, 20, 30, 40, 50, 60, 10]) == 40)
        #expect(ConnectionSpeed.bestSustained([50, 50]) == 0)
    }
}
