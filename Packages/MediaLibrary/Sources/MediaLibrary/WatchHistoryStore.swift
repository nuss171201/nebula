import Foundation
import GRDB
import MediaCore

/// What is needed to file a video in the watch history: which video, of which title, and
/// enough about the title to show it later without asking the network.
public struct WatchVideo: Sendable, Hashable {
    public var type: MediaType
    /// The title's id for a film; the episode's id for a series.
    public var videoID: String
    /// The film or series.
    public var titleID: String
    public var titleName: String
    public var poster: URL?
    public var season: Int?
    public var episode: Int?
    /// The episode's own title.
    public var videoTitle: String?

    public init(
        type: MediaType,
        videoID: String,
        titleID: String,
        titleName: String,
        poster: URL? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        videoTitle: String? = nil
    ) {
        self.type = type
        self.videoID = videoID
        self.titleID = titleID
        self.titleName = titleName
        self.poster = poster
        self.season = season
        self.episode = episode
        self.videoTitle = videoTitle
    }
}

/// One video's place in the watch history.
public struct WatchEntry: Sendable, Hashable, Identifiable {
    public var video: WatchVideo
    /// Seconds from the start where it was left. 0 once it has been watched to the end.
    public var position: Double
    public var duration: Double?
    public var isWatched: Bool
    public var lastWatchedAt: Date

    public init(video: WatchVideo, position: Double, duration: Double?, isWatched: Bool, lastWatchedAt: Date) {
        self.video = video
        self.position = position
        self.duration = duration
        self.isWatched = isWatched
        self.lastWatchedAt = lastWatchedAt
    }

    public var id: String {
        "\(video.type.rawValue)|\(video.videoID)"
    }

    /// How far through it is, 0 to 1; `nil` when the length is not known.
    public var progress: Double? {
        guard let duration, duration > 0 else { return nil }
        return isWatched ? 1 : min(max(position / duration, 0), 1)
    }

    /// Whether it was started and not finished.
    public var isInProgress: Bool {
        !isWatched && position > 0
    }
}

/// Where a video was left when the player let go of it.
public enum WatchPoint: Sendable, Equatable {
    /// Barely begun: nothing worth coming back to.
    case notStarted
    /// Seconds from the start.
    case at(Double)
    /// Watched to the end.
    case finished
}

/// What has been watched, how far, and when.
public struct WatchHistoryStore: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    /// Notes that a video is being played now: creates its entry or refreshes the title's
    /// name and poster, and puts it back on Continue Watching if it had been taken off.
    public func begin(_ video: WatchVideo, now: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO watchEntry (type, videoID, titleID, titleName, poster, season, episode, videoTitle, lastWatchedAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(type, videoID) DO UPDATE SET
                    titleID = excluded.titleID, titleName = excluded.titleName, poster = excluded.poster,
                    season = excluded.season, episode = excluded.episode, videoTitle = excluded.videoTitle,
                    isDismissed = 0, lastWatchedAt = excluded.lastWatchedAt, updatedAt = excluded.updatedAt
                """,
                arguments: [
                    video.type.rawValue, video.videoID, video.titleID, video.titleName, video.poster?.absoluteString,
                    video.season, video.episode, video.videoTitle, now, now,
                ]
            )
        }
    }

    /// Stores where a video was left. Does nothing for a video that was never begun.
    public func record(_ point: WatchPoint, duration: Double?, type: MediaType, videoID: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            switch point {
            case .notStarted:
                try db.execute(
                    sql: """
                    UPDATE watchEntry SET position = 0, duration = COALESCE(?, duration), lastWatchedAt = ?, updatedAt = ?
                    WHERE type = ? AND videoID = ?
                    """,
                    arguments: [duration, now, now, type.rawValue, videoID]
                )
            case let .at(position):
                try db.execute(
                    sql: """
                    UPDATE watchEntry SET position = ?, duration = COALESCE(?, duration), isWatched = 0, isDismissed = 0,
                        lastWatchedAt = ?, updatedAt = ?
                    WHERE type = ? AND videoID = ?
                    """,
                    arguments: [max(position, 0), duration, now, now, type.rawValue, videoID]
                )
            case .finished:
                try db.execute(
                    sql: """
                    UPDATE watchEntry SET position = 0, duration = COALESCE(?, duration), isWatched = 1,
                        lastWatchedAt = ?, updatedAt = ?
                    WHERE type = ? AND videoID = ?
                    """,
                    arguments: [duration, now, now, type.rawValue, videoID]
                )
            }
        }
    }

    /// Marks videos as watched or not, creating entries for ones that were never played.
    /// Marking as not watched also forgets where they were left.
    public func setWatched(_ isWatched: Bool, videos: [WatchVideo], now: Date = Date()) async throws {
        guard !videos.isEmpty else { return }
        try await database.writer.write { db in
            for video in videos {
                try db.execute(
                    sql: """
                    INSERT INTO watchEntry (type, videoID, titleID, titleName, poster, season, episode, videoTitle,
                        position, isWatched, lastWatchedAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                    ON CONFLICT(type, videoID) DO UPDATE SET position = 0, isWatched = excluded.isWatched, updatedAt = excluded.updatedAt
                    """,
                    arguments: [
                        video.type.rawValue, video.videoID, video.titleID, video.titleName, video.poster?.absoluteString,
                        video.season, video.episode, video.videoTitle, isWatched, now, now,
                    ]
                )
            }
        }
    }

    public func entry(type: MediaType, videoID: String) async throws -> WatchEntry? {
        try await database.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM watchEntry WHERE type = ? AND videoID = ?", arguments: [type.rawValue, videoID])
                .map(Self.entry(from:))
        }
    }

    /// Every entry of one title (all the episodes of a series that have one), by video id.
    public func entries(type: MediaType, titleID: String) async throws -> [String: WatchEntry] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM watchEntry WHERE type = ? AND titleID = ?", arguments: [type.rawValue, titleID])
            return Dictionary(rows.map { row in (row["videoID"] as String, Self.entry(from: row)) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// For each title, the video that was watched most recently, newest first; titles the user
    /// took off the row are left out. The caller decides what each means: resume it, or move
    /// on to the next episode.
    public func latestPerTitle(limit: Int = 30) async throws -> [WatchEntry] {
        try await database.writer.read { db in
            // SQLite returns the other columns from the row that holds MAX(lastWatchedAt).
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *, MAX(lastWatchedAt) AS latest FROM watchEntry
                GROUP BY type, titleID
                HAVING isDismissed = 0
                ORDER BY latest DESC LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.map(Self.entry(from:))
        }
    }

    /// Takes a title off the Continue Watching row. What was watched stays in the history.
    public func dismiss(type: MediaType, titleID: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE watchEntry SET isDismissed = 1, updatedAt = ? WHERE type = ? AND titleID = ?",
                arguments: [now, type.rawValue, titleID]
            )
        }
    }

    /// Everything that was played, most recent first.
    public func history(limit: Int = 200) async throws -> [WatchEntry] {
        try await database.writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM watchEntry WHERE position > 0 OR isWatched = 1 ORDER BY lastWatchedAt DESC LIMIT ?",
                arguments: [limit]
            ).map(Self.entry(from:))
        }
    }

    /// Forgets the whole history.
    public func clear() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM watchEntry")
        }
    }

    private static func entry(from row: Row) -> WatchEntry {
        WatchEntry(
            video: WatchVideo(
                type: MediaType(rawValue: row["type"]),
                videoID: row["videoID"],
                titleID: row["titleID"],
                titleName: row["titleName"],
                poster: (row["poster"] as String?).flatMap(URL.init(string:)),
                season: row["season"],
                episode: row["episode"],
                videoTitle: row["videoTitle"]
            ),
            position: row["position"],
            duration: row["duration"],
            isWatched: row["isWatched"],
            lastWatchedAt: row["lastWatchedAt"]
        )
    }
}
