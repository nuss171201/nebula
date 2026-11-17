import Foundation
import MediaCore
import MediaLibrary
import Observation
import os

/// The one place the screens go for saved titles and watch history.
///
/// Every change bumps `revision`; a screen that shows any of this reads `revision` and
/// reloads when it moves, so that marking an episode watched on one page is seen on all.
@MainActor
@Observable
public final class LibraryCenter {
    public private(set) var revision = 0

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let history: WatchHistoryStore
    @ObservationIgnored private let logger: Logger

    public init(library: LibraryStore, history: WatchHistoryStore, logSubsystem: String = "library") {
        self.library = library
        self.history = history
        logger = Logger(subsystem: logSubsystem, category: "library")
    }

    /// Something was written from elsewhere (the player saving where a video was left).
    public func noteChange() {
        revision += 1
    }

    // MARK: - Saved titles

    public func isSaved(type: MediaType, id: String) async -> Bool {
        await attempt(false) { try await library.contains(type: type, id: id) }
    }

    public func save(_ meta: MetaItem) async {
        let item = LibraryItem(
            type: meta.type,
            id: meta.id,
            name: meta.name,
            poster: meta.poster,
            posterShape: meta.posterShape.rawValue,
            releaseInfo: meta.releaseInfo
        )
        await change { try await library.add(item) }
    }

    public func remove(type: MediaType, id: String) async {
        await change { try await library.remove(type: type, id: id) }
    }

    public func items(type: MediaType? = nil, order: LibraryStore.Order = .recentlyAdded) async -> [LibraryItem] {
        await attempt([]) { try await library.items(type: type, order: order) }
    }

    // MARK: - Watch history

    /// A video is about to be played.
    public func begin(_ video: WatchVideo) async {
        await change { try await history.begin(video) }
    }

    public func setWatched(_ isWatched: Bool, videos: [WatchVideo]) async {
        await change { try await history.setWatched(isWatched, videos: videos) }
    }

    public func entries(type: MediaType, titleID: String) async -> [String: WatchEntry] {
        await attempt([:]) { try await history.entries(type: type, titleID: titleID) }
    }

    public func latestPerTitle() async -> [WatchEntry] {
        await attempt([]) { try await history.latestPerTitle() }
    }

    public func watchHistory() async -> [WatchEntry] {
        await attempt([]) { try await history.history() }
    }

    /// Takes a title off the Continue Watching row.
    public func dismissFromContinueWatching(type: MediaType, titleID: String) async {
        await change { try await history.dismiss(type: type, titleID: titleID) }
    }

    public func clearHistory() async {
        await change { try await history.clear() }
    }

    // MARK: - Helpers

    /// A read: storage trouble is logged and shows as "nothing there" rather than breaking a screen.
    private func attempt<Value: Sendable>(_ fallback: Value, _ read: @Sendable () async throws -> Value) async -> Value {
        do {
            return try await read()
        } catch {
            logger.error("library read failed: \(error.localizedDescription, privacy: .public)")
            return fallback
        }
    }

    private func change(_ write: @Sendable () async throws -> Void) async {
        do {
            try await write()
        } catch {
            logger.error("library write failed: \(error.localizedDescription, privacy: .public)")
        }
        revision += 1
    }
}

/// The names the player remembers things under, for videos that come from a catalog.
enum WatchKey {
    /// `video:<type>:<video id>`; the id may itself contain colons.
    static func make(type: MediaType, videoID: String) -> String {
        "video:\(type.rawValue):\(videoID)"
    }

    static func parse(_ key: String) -> (type: MediaType, videoID: String)? {
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "video", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return (MediaType(rawValue: String(parts[1])), String(parts[2]))
    }
}
