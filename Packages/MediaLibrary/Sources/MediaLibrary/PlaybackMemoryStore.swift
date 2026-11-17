import Foundation
import GRDB

/// Remembers small per-title values for the player (which tracks the user chose, say),
/// keyed by names the caller makes up: a file path, a folder, a series id.
///
/// Values are stored as JSON so this package does not need to know the player's types.
public struct PlaybackMemoryStore: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    /// The value stored under the first of `keys` that has a readable one.
    public func value<Value: Codable & Sendable>(forAnyOf keys: [String], as _: Value.Type = Value.self) async throws -> Value? {
        guard !keys.isEmpty else { return nil }
        let stored = try await database.writer.read { db in
            let placeholders = keys.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT key, value FROM playbackMemory WHERE key IN (\(placeholders))",
                arguments: StatementArguments(keys)
            )
            return Dictionary(rows.map { ($0["key"] as String, $0["value"] as String) }, uniquingKeysWith: { first, _ in first })
        }
        for key in keys {
            if let json = stored[key], let value = try? JSONDecoder().decode(Value.self, from: Data(json.utf8)) {
                return value
            }
        }
        return nil
    }

    /// Stores the value under every key.
    public func set(_ value: some Codable & Sendable, for keys: [String], now: Date = Date()) async throws {
        guard !keys.isEmpty else { return }
        // JSONEncoder always produces valid UTF-8, so the non-failable conversion is exact.
        // swiftlint:disable:next optional_data_string_conversion
        let json = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        try await database.writer.write { db in
            for key in keys {
                try db.execute(
                    sql: """
                    INSERT INTO playbackMemory (key, value, updatedAt) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                    """,
                    arguments: [key, json, now]
                )
            }
        }
    }

    public func remove(keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        try await database.writer.write { db in
            for key in keys {
                try db.execute(sql: "DELETE FROM playbackMemory WHERE key = ?", arguments: [key])
            }
        }
    }
}
