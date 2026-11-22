import Foundation
import GRDB

/// The list of downloads: what was asked for, how far each has come and where its file is.
///
/// Rows are stored as JSON so that this package need not know the app's types; a row that
/// can no longer be read (written by another version) is left out, not fatal.
public struct DownloadStore: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    /// Every download, in the order they were added.
    public func all<Value: Codable & Sendable>(as _: Value.Type = Value.self) async throws -> [Value] {
        let payloads = try await database.writer.read { db in
            try String.fetchAll(db, sql: "SELECT payload FROM download ORDER BY addedAt, id")
        }
        let decoder = JSONDecoder()
        return payloads.compactMap { try? decoder.decode(Value.self, from: Data($0.utf8)) }
    }

    /// Adds a download, or replaces the one with this id (keeping its place in the list).
    public func save(_ value: some Codable & Sendable, id: String, now: Date = Date()) async throws {
        // JSONEncoder always produces valid UTF-8, so the non-failable conversion is exact.
        // swiftlint:disable:next optional_data_string_conversion
        let json = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO download (id, payload, addedAt, updatedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updatedAt = excluded.updatedAt
                """,
                arguments: [id, json, now, now]
            )
        }
    }

    public func remove(id: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM download WHERE id = ?", arguments: [id])
        }
    }
}
