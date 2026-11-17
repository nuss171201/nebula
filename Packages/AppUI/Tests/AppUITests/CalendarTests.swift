import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary
import Testing

/// A calendar that does not depend on where the tests run.
private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
}

/// Noon on 15 June 2026, UTC.
private let noon = Date(timeIntervalSince1970: 1_781_524_800)
private let day: TimeInterval = 86400

private func series(_ id: String, _ name: String, episodes: [(Int, Int, TimeInterval?)]) -> MetaItem {
    MetaItem(id: id, type: .series, name: name, videos: episodes.map { season, number, offset in
        MetaVideo(id: "\(id):\(season):\(number)", title: "Episode \(number)", released: offset.map { noon + $0 }, season: season, episode: number)
    })
}

@Suite("Calendar (pure)")
struct CalendarBuilderTests {
    @Test("Episodes from a week back to three months ahead are grouped by day, earliest first")
    func window() {
        let shows = [
            series("tt2", "Beta", episodes: [(1, 1, -8 * day), (1, 2, -7 * day), (1, 3, 0), (1, 4, 90 * day), (1, 5, 91 * day), (1, 6, nil)]),
            series("tt1", "Alpha", episodes: [(2, 1, 3600), (2, 2, 2 * day)]),
        ]
        let days = CalendarBuilder.days(from: shows, now: noon, calendar: utc)
        // Eight days ago and ninety-one days ahead are outside; so is an episode without a date.
        #expect(days.map { Int(($0.date.timeIntervalSince(utc.startOfDay(for: noon)) / day).rounded()) } == [-7, 0, 2, 90])
        // Within a day: by time, so the noon episode comes before the one an hour later.
        #expect(days[1].episodes.map(\.id) == ["tt2:1:3", "tt1:2:1"])
        #expect(days[1].episodes[1].seriesName == "Alpha")
        #expect(days[1].episodes[0].episodeLine == "S1 · E3 — Episode 3")
        #expect(days[2].episodes[0].watchVideo == WatchVideo(
            type: .series, videoID: "tt1:2:2", titleID: "tt1", titleName: "Alpha", season: 2, episode: 2, videoTitle: "Episode 2"
        ))
    }

    @Test("Days are cut at midnight in the calendar's own time zone, and an episode listed twice appears once")
    func timeZones() {
        // 23:30 UTC on the 15th is already the 16th in Tokyo.
        let late = series("tt1", "Alpha", episodes: [(1, 1, 11.5 * 3600)])
        var tokyo = utc
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        let inUTC = CalendarBuilder.days(from: [late], now: noon, calendar: utc)
        let inTokyo = CalendarBuilder.days(from: [late], now: noon, calendar: tokyo)
        #expect(CalendarBuilder.title(for: inUTC[0].date, now: noon, calendar: utc) == "Today")
        #expect(CalendarBuilder.title(for: inTokyo[0].date, now: noon, calendar: tokyo) == "Tomorrow")

        #expect(CalendarBuilder.days(from: [late, late], now: noon, calendar: utc).flatMap(\.episodes).count == 1)
        #expect(CalendarBuilder.days(from: [], now: noon, calendar: utc).isEmpty)
    }

    @Test("Days near today are named; others carry their date")
    func titles() {
        let today = utc.startOfDay(for: noon)
        #expect(CalendarBuilder.title(for: today - day, now: noon, calendar: utc) == "Yesterday")
        #expect(CalendarBuilder.title(for: today + day, now: noon, calendar: utc) == "Tomorrow")
        let later = CalendarBuilder.title(for: today + 5 * day, now: noon, calendar: utc, locale: Locale(identifier: "en_US"))
        #expect(later == "Saturday, June 20, 2026")
    }

    @Test("Series ids are asked about in groups no larger than the catalog accepts")
    func batches() {
        let ids = (1 ... 7).map { "tt\($0)" }
        #expect(CalendarBuilder.batches(of: ids, size: 3).map(\.count) == [3, 3, 1])
        #expect(CalendarBuilder.batches(of: ids, size: 100) == [ids])
        #expect(CalendarBuilder.batches(of: [], size: 3).isEmpty)
        #expect(CalendarBuilder.batches(of: ids, size: 0).count == 7)
    }
}

@MainActor
@Suite("Calendar from the library's series")
struct CalendarModelTests {
    private func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private func detailed(_ id: String, _ name: String, episodeAt date: Date) -> String {
        let video = #"{"id": "\#(id):1:1", "name": "One", "season": 1, "episode": 1, "released": "\#(iso(date))"}"#
        return #"{"id": "\#(id)", "type": "series", "name": "\#(name)", "videos": [\#(video)]}"#
    }

    @Test("Saved series are asked about in one calendar request; films are left out; a series the catalog does not answer for is asked about by itself")
    func loads() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        let center = LibraryCenter(library: LibraryStore(database: harness.database), history: WatchHistoryStore(database: harness.database))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try await LibraryStore(database: harness.database).add(LibraryItem(type: .series, id: "tt0000042", name: "Example Show"), now: start + 2)
        try await LibraryStore(database: harness.database).add(LibraryItem(type: .series, id: "tt0000043", name: "Other Show"), now: start + 1)
        try await LibraryStore(database: harness.database).add(LibraryItem(type: .movie, id: "tt0000001", name: "Example Movie"), now: start)

        // The calendar catalog knows only the first series.
        harness.server.respond(
            to: "/catalog/series/calendar-videos/calendarVideosIds=tt0000042%2Ctt0000043.json",
            with: .json(#"{"metasDetailed": [\#(detailed("tt0000042", "Example Show", episodeAt: noon + day))]}"#)
        )
        harness.server.respond(
            to: "/meta/series/tt0000043.json",
            with: .json(#"{"meta": \#(detailed("tt0000043", "Other Show", episodeAt: noon + 3 * day))}"#)
        )
        let model = CalendarModel(library: center, client: harness.client)
        try await model.update(addons: [harness.installedAddon()])
        #expect(model.phase == .idle)

        await model.reload(now: noon, calendar: utc)
        #expect(model.phase == .loaded && model.hasSeries)
        #expect(model.days.flatMap(\.episodes).map(\.seriesName) == ["Example Show", "Other Show"])
        #expect(harness.server.requestCount(for: "/catalog/series/calendar-videos/calendarVideosIds=tt0000042%2Ctt0000043.json") == 1)
        #expect(harness.server.requestCount(for: "/meta/series/tt0000042.json") == 0)
        #expect(harness.server.requestCount(for: "/meta/movie/tt0000001.json") == 0)
    }

    @Test("An empty library, a library without series and add-ons that do not answer each say what is the matter")
    func emptyAndFailed() async throws {
        let harness = try await AddonHarness.make()
        defer { harness.server.stop() }
        let store = LibraryStore(database: harness.database)
        let center = LibraryCenter(library: store, history: WatchHistoryStore(database: harness.database))
        let model = CalendarModel(library: center, client: harness.client)
        try await model.update(addons: [harness.installedAddon()])

        await model.reload(now: noon, calendar: utc)
        #expect(model.phase == .loaded && !model.hasSeries && model.days.isEmpty)
        try await store.add(LibraryItem(type: .movie, id: "tt0000001", name: "Example Movie"))
        await model.reload(now: noon, calendar: utc)
        #expect(!model.hasSeries)

        // A series is saved, but the add-on is down.
        try await store.add(LibraryItem(type: .series, id: "tt0000042", name: "Example Show"))
        harness.server.respond(to: "/catalog/series/calendar-videos/calendarVideosIds=tt0000042.json", with: .status(500))
        harness.server.respond(to: "/meta/series/tt0000042.json", with: .status(500))
        await model.reload(now: noon, calendar: utc)
        #expect(model.hasSeries && model.days.isEmpty)
        guard case .failed = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }

        // It comes back, with nothing in the window: loaded, and empty.
        harness.server.respond(
            to: "/catalog/series/calendar-videos/calendarVideosIds=tt0000042.json",
            with: .json(#"{"metasDetailed": [\#(detailed("tt0000042", "Example Show", episodeAt: noon - 400 * day))]}"#)
        )
        await model.reload(now: noon, calendar: utc)
        #expect(model.phase == .loaded && model.days.isEmpty)
    }
}
