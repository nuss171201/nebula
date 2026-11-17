import Foundation
import GRDB
import MediaCore

/// A title the user saved to their library.
public struct LibraryItem: Sendable, Hashable, Identifiable {
    public var type: MediaType
    public var id: String
    public var name: String
    public var poster: URL?
    /// The poster's shape as the catalog names it (`poster`, `landscape`, `square`).
    public var posterShape: String?
    /// The year or run of years.
    public var releaseInfo: String?
    public var addedAt: Date

    public init(
        type: MediaType,
        id: String,
        name: String,
        poster: URL? = nil,
        posterShape: String? = nil,
        releaseInfo: String? = nil,
        addedAt: Date = Date()
    ) {
        self.type = type
        self.id = id
        self.name = name
        self.poster = poster
        self.posterShape = posterShape
        self.releaseInfo = releaseInfo
        self.addedAt = addedAt
    }
}

/// The user's saved titles.
public struct LibraryStore: Sendable {
    public enum Order: Sendable {
        case recentlyAdded
        case name
    }

    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    /// Saves a title, or refreshes its name and poster if it is already saved. A title that
    /// was removed and is added again counts as added now.
    public func add(_ item: LibraryItem, now: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO libraryItem (type, id, name, poster, posterShape, releaseInfo, addedAt, removedAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
                ON CONFLICT(type, id) DO UPDATE SET
                    name = excluded.name, poster = excluded.poster, posterShape = excluded.posterShape,
                    releaseInfo = excluded.releaseInfo,
                    addedAt = CASE WHEN libraryItem.removedAt IS NULL THEN libraryItem.addedAt ELSE excluded.addedAt END,
                    removedAt = NULL, updatedAt = excluded.updatedAt
                """,
                arguments: [item.type.rawValue, item.id, item.name, item.poster?.absoluteString, item.posterShape, item.releaseInfo, now, now]
            )
        }
    }

    /// Takes a title out of the library.
    public func remove(type: MediaType, id: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE libraryItem SET removedAt = ?, updatedAt = ? WHERE type = ? AND id = ? AND removedAt IS NULL",
                arguments: [now, now, type.rawValue, id]
            )
        }
    }

    public func contains(type: MediaType, id: String) async throws -> Bool {
        try await database.writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM libraryItem WHERE type = ? AND id = ? AND removedAt IS NULL)",
                arguments: [type.rawValue, id]
            ) ?? false
        }
    }

    /// Saved titles, optionally of one type only.
    public func items(type: MediaType? = nil, order: Order = .recentlyAdded) async throws -> [LibraryItem] {
        try await database.writer.read { db in
            let ordering = switch order {
            case .recentlyAdded: "addedAt DESC, name COLLATE NOCASE"
            case .name: "name COLLATE NOCASE, addedAt DESC"
            }
            let rows = if let type {
                try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM libraryItem WHERE removedAt IS NULL AND type = ? ORDER BY \(ordering)",
                    arguments: [type.rawValue]
                )
            } else {
                try Row.fetchAll(db, sql: "SELECT * FROM libraryItem WHERE removedAt IS NULL ORDER BY \(ordering)")
            }
            return rows.map(Self.item(from:))
        }
    }

    private static func item(from row: Row) -> LibraryItem {
        LibraryItem(
            type: MediaType(rawValue: row["type"]),
            id: row["id"],
            name: row["name"],
            poster: (row["poster"] as String?).flatMap(URL.init(string:)),
            posterShape: row["posterShape"],
            releaseInfo: row["releaseInfo"],
            addedAt: row["addedAt"]
        )
    }
}
