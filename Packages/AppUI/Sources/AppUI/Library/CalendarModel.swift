import Foundation
import MediaCore
import MediaLibrary
import Observation

/// One episode on the calendar.
public struct CalendarEpisode: Sendable, Hashable, Identifiable {
    public var seriesID: String
    public var seriesName: String
    public var poster: URL?
    public var type: MediaType
    public var video: MetaVideo
    public var date: Date

    public var id: String { video.id }

    /// The episode as the watch history files it, for opening its page.
    public var watchVideo: WatchVideo {
        WatchVideo(
            type: type, videoID: video.id, titleID: seriesID, titleName: seriesName,
            poster: poster, season: video.season, episode: video.episode, videoTitle: video.title
        )
    }

    /// "S2 · E5 — The Title".
    public var episodeLine: String {
        ContinueItem(video: watchVideo, kind: .nextEpisode).episodeLine ?? video.title
    }
}

/// The episodes of one day.
public struct CalendarDay: Sendable, Hashable, Identifiable {
    /// The start of the day in the calendar's time zone.
    public var date: Date
    public var episodes: [CalendarEpisode]

    public var id: Date { date }
}

/// Turning series metadata into a calendar. Pure, so the rules can be tested with fixed dates.
public enum CalendarBuilder {
    /// How far back and ahead the calendar looks.
    public static let daysBack = 7
    public static let daysAhead = 90

    /// Episodes from a week ago to three months ahead, grouped by day, earliest first; within
    /// a day by time, then by series name.
    public static func days(from series: [MetaItem], now: Date, calendar: Calendar = .current) -> [CalendarDay] {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -daysBack, to: today),
              let end = calendar.date(byAdding: .day, value: daysAhead + 1, to: today)
        else { return [] }

        var seen = Set<String>()
        let episodes = series.flatMap { meta in
            meta.videos.compactMap { video -> CalendarEpisode? in
                guard let released = video.released, released >= start, released < end, seen.insert(video.id).inserted else { return nil }
                return CalendarEpisode(seriesID: meta.id, seriesName: meta.name, poster: meta.poster, type: meta.type, video: video, date: released)
            }
        }
        let grouped = Dictionary(grouping: episodes) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { day in
            let list = (grouped[day] ?? []).sorted {
                ($0.date, $0.seriesName, $0.video.episode ?? 0) < ($1.date, $1.seriesName, $1.video.episode ?? 0)
            }
            return CalendarDay(date: day, episodes: list)
        }
    }

    /// "Today", "Tomorrow", "Yesterday", or the date with its weekday.
    public static func title(for day: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let today = calendar.startOfDay(for: now)
        switch calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: day)).day {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            var style = Date.FormatStyle(date: .complete, time: .omitted)
            style.locale = locale
            style.timeZone = calendar.timeZone
            style.calendar = calendar
            return day.formatted(style)
        }
    }

    /// Splits ids into the groups a calendar catalog accepts at once.
    static func batches(of ids: [String], size: Int) -> [[String]] {
        let size = max(size, 1)
        return stride(from: 0, to: ids.count, by: size).map { Array(ids[$0 ..< min($0 + size, ids.count)]) }
    }
}

/// The calendar: recent and upcoming episodes of the series saved in the library.
@MainActor
@Observable
public final class CalendarModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase = Phase.idle
    public private(set) var days: [CalendarDay] = []
    /// Whether the library has any series at all.
    public private(set) var hasSeries = false

    @ObservationIgnored private let library: LibraryCenter
    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private var addons: [InstalledAddon] = []
    @ObservationIgnored private var generation = 0
    /// At most this many series are asked about one by one when no add-on has a calendar catalog.
    static let individualLimit = 40

    public init(library: LibraryCenter, client: AddonClient) {
        self.library = library
        self.client = client
    }

    public func update(addons: [InstalledAddon]) {
        self.addons = addons
    }

    /// Reads the library's series and asks the add-ons about their episodes.
    public func reload(now: Date = Date(), calendar: Calendar = .current) async {
        generation += 1
        let current = generation
        let series = await library.items().filter { $0.type == .series }
        guard current == generation else { return }
        hasSeries = !series.isEmpty
        guard hasSeries else {
            days = []
            phase = .loaded
            return
        }
        if days.isEmpty {
            phase = .loading
        }

        let (metas, failure) = await fetch(series)
        guard current == generation else { return }
        days = CalendarBuilder.days(from: metas, now: now, calendar: calendar)
        phase = metas.isEmpty && failure != nil ? .failed(failure ?? "") : .loaded
    }

    /// Episode lists for the saved series: from a calendar catalog where an add-on has one
    /// (one request for up to a hundred series), otherwise series by series.
    private func fetch(_ series: [LibraryItem]) async -> (metas: [MetaItem], failure: String?) {
        var remaining = series
        var metas: [MetaItem] = []
        var failure: String?

        for source in addons.catalogSources {
            guard let extra = source.catalog.extraProperty(named: ManifestCatalog.calendarExtra) else { continue }
            let supported = remaining.filter { item in
                item.type == source.catalog.type && source.addon.manifest.supports(resource: ManifestResource.meta, type: item.type, id: item.id)
            }
            for batch in CalendarBuilder.batches(of: supported.map(\.id), size: extra.optionsLimit ?? 100) {
                do {
                    let found = try await calendarBatch(batch, from: source)
                    metas += found
                    let answered = Set(found.map(\.id))
                    remaining.removeAll { answered.contains($0.id) }
                } catch where !error.isCancellation {
                    failure = error.userMessage
                } catch {}
            }
        }
        // Whatever no calendar catalog covered: each series' own page.
        metas += await individually(Array(remaining.prefix(Self.individualLimit)))
        return (metas, failure)
    }

    private func calendarBatch(_ ids: [String], from source: CatalogSource) async throws(AddonError) -> [MetaItem] {
        let request = CatalogRequest(
            type: source.catalog.type,
            catalogID: source.catalog.id,
            extra: [.init(ManifestCatalog.calendarExtra, ids.joined(separator: ","))]
        )
        return try await client.detailedCatalog(request, from: source.addon.address)
    }

    private func individually(_ series: [LibraryItem]) async -> [MetaItem] {
        await withTaskGroup(of: MetaItem?.self) { group in
            for item in series {
                let providers = addons.serving(resource: ManifestResource.meta, type: item.type, id: item.id)
                group.addTask { [client] in
                    for provider in providers {
                        if let meta = try? await client.meta(type: item.type, id: item.id, from: provider.address) {
                            return meta
                        }
                    }
                    return nil
                }
            }
            var metas: [MetaItem] = []
            for await meta in group {
                if let meta {
                    metas.append(meta)
                }
            }
            return metas
        }
    }
}
