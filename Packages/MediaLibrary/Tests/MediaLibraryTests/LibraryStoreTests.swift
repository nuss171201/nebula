import Foundation
import MediaCore
@testable import MediaLibrary
import Testing

@Suite("Library of saved titles")
struct LibraryStoreTests {
    private let day: TimeInterval = 86400
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func film(_ id: String, _ name: String) -> LibraryItem {
        LibraryItem(type: .movie, id: id, name: name, poster: URL(string: "https://images.example.com/\(id).jpg"), releaseInfo: "2001")
    }

    @Test("Saved titles are listed newest first or by name, and by type")
    func listing() async throws {
        let store = try LibraryStore(database: .inMemory())
        try await store.add(film("tt1", "beta"), now: start)
        try await store.add(film("tt2", "Alpha"), now: start + day)
        try await store.add(LibraryItem(type: .series, id: "tt3", name: "Gamma"), now: start + 2 * day)

        #expect(try await store.items().map(\.name) == ["Gamma", "Alpha", "beta"])
        #expect(try await store.items(order: .name).map(\.name) == ["Alpha", "beta", "Gamma"])
        #expect(try await store.items(type: .movie).map(\.id) == ["tt2", "tt1"])
        #expect(try await store.items(type: .series).first?.poster == nil)
        #expect(try await store.items(type: .movie).first?.poster?.absoluteString == "https://images.example.com/tt2.jpg")
        #expect(try await store.contains(type: .movie, id: "tt1"))
        // The same id under another type is another title.
        #expect(try await !store.contains(type: .series, id: "tt1"))
    }

    @Test("Saving again refreshes the details and keeps the date; removing and saving again starts afresh")
    func addingAndRemoving() async throws {
        let store = try LibraryStore(database: .inMemory())
        try await store.add(film("tt1", "Old Name"), now: start)
        try await store.add(film("tt1", "New Name"), now: start + day)
        let saved = try #require(await store.items().first)
        #expect(saved.name == "New Name" && saved.addedAt == start)

        try await store.remove(type: .movie, id: "tt1", now: start + 2 * day)
        #expect(try await store.items().isEmpty)
        #expect(try await !store.contains(type: .movie, id: "tt1"))
        // Removing what is not there does nothing.
        try await store.remove(type: .movie, id: "tt404")

        try await store.add(film("tt1", "New Name"), now: start + 3 * day)
        #expect(try await store.items().first?.addedAt == start + 3 * day)
    }
}

@Suite("Watch history")
struct WatchHistoryStoreTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func episode(_ number: Int, series: String = "tt42", name: String = "Example Show") -> WatchVideo {
        WatchVideo(
            type: .series, videoID: "\(series):1:\(number)", titleID: series, titleName: name,
            poster: URL(string: "https://images.example.com/\(series).jpg"), season: 1, episode: number, videoTitle: "Episode \(number)"
        )
    }

    private let film = WatchVideo(type: .movie, videoID: "tt1", titleID: "tt1", titleName: "Example Film")

    @Test("A video that is played gets an entry, which follows where it is left, to the end")
    func progress() async throws {
        let store = try WatchHistoryStore(database: .inMemory())
        // Nothing is recorded for a video that was never begun.
        try await store.record(.at(100), duration: 1000, type: .movie, videoID: "tt1")
        #expect(try await store.entry(type: .movie, videoID: "tt1") == nil)

        try await store.begin(film, now: start)
        var entry = try #require(await store.entry(type: .movie, videoID: "tt1"))
        #expect(entry.position == 0 && !entry.isWatched && !entry.isInProgress && entry.progress == nil)

        try await store.record(.at(250), duration: 1000, type: .movie, videoID: "tt1", now: start + 60)
        entry = try #require(await store.entry(type: .movie, videoID: "tt1"))
        #expect(entry.position == 250 && entry.duration == 1000 && entry.progress == 0.25 && entry.isInProgress)
        #expect(entry.lastWatchedAt == start + 60)
        #expect(entry.video == film)

        // The length is kept when a later report does not know it.
        try await store.record(.finished, duration: nil, type: .movie, videoID: "tt1", now: start + 120)
        entry = try #require(await store.entry(type: .movie, videoID: "tt1"))
        #expect(entry.isWatched && entry.position == 0 && entry.duration == 1000 && entry.progress == 1 && !entry.isInProgress)

        // Watching it again from the middle makes it unfinished again.
        try await store.record(.at(500), duration: 1000, type: .movie, videoID: "tt1", now: start + 180)
        #expect(try await store.entry(type: .movie, videoID: "tt1")?.isWatched == false)
    }

    @Test("Each title appears once in the latest list, by its most recently watched video")
    func latestPerTitle() async throws {
        let store = try WatchHistoryStore(database: .inMemory())
        try await store.begin(episode(1), now: start)
        try await store.record(.finished, duration: 1200, type: .series, videoID: "tt42:1:1", now: start + 10)
        try await store.begin(episode(2), now: start + 20)
        try await store.record(.at(300), duration: 1200, type: .series, videoID: "tt42:1:2", now: start + 30)
        try await store.begin(film, now: start + 25)
        try await store.record(.at(40), duration: 5000, type: .movie, videoID: "tt1", now: start + 26)

        let latest = try await store.latestPerTitle()
        #expect(latest.map(\.video.videoID) == ["tt42:1:2", "tt1"])
        #expect(latest[0].position == 300 && latest[0].video.episode == 2)
        #expect(try await store.latestPerTitle(limit: 1).count == 1)
        #expect(try await store.entries(type: .series, titleID: "tt42").keys.sorted() == ["tt42:1:1", "tt42:1:2"])
        #expect(try await store.history().map(\.video.videoID) == ["tt42:1:2", "tt1", "tt42:1:1"])
    }

    @Test("A title taken off Continue Watching stays in the history and comes back when watched again")
    func dismissing() async throws {
        let store = try WatchHistoryStore(database: .inMemory())
        try await store.begin(episode(1), now: start)
        try await store.record(.at(300), duration: 1200, type: .series, videoID: "tt42:1:1", now: start + 10)
        try await store.dismiss(type: .series, titleID: "tt42")
        #expect(try await store.latestPerTitle().isEmpty)
        #expect(try await store.history().count == 1)

        try await store.begin(episode(2), now: start + 100)
        #expect(try await store.latestPerTitle().map(\.video.videoID) == ["tt42:1:2"])
    }

    @Test("Videos can be marked watched or not without playing them; unmarking forgets where they were left")
    func marking() async throws {
        let store = try WatchHistoryStore(database: .inMemory())
        try await store.begin(episode(1), now: start)
        try await store.record(.at(300), duration: 1200, type: .series, videoID: "tt42:1:1", now: start + 10)

        try await store.setWatched(true, videos: [episode(1), episode(2), episode(3)], now: start + 20)
        let entries = try await store.entries(type: .series, titleID: "tt42")
        #expect(entries.count == 3 && entries.values.allSatisfy(\.isWatched))
        #expect(entries["tt42:1:1"]?.position == 0 && entries["tt42:1:1"]?.duration == 1200)
        #expect(entries["tt42:1:3"]?.video.videoTitle == "Episode 3")

        try await store.setWatched(false, videos: [episode(2)], now: start + 30)
        let after = try #require(await store.entry(type: .series, videoID: "tt42:1:2"))
        #expect(!after.isWatched && after.position == 0)
        // Marked but never played: not part of the history of what was played… unless watched.
        #expect(try await store.history().map(\.video.videoID).sorted() == ["tt42:1:1", "tt42:1:3"])
        try await store.setWatched(true, videos: [])

        try await store.clear()
        #expect(try await store.history().isEmpty)
    }
}
