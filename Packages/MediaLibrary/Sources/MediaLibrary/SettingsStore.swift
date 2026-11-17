import Foundation
import GRDB

/// A typed setting: its storage name and the value used until the user changes it.
public struct SettingKey<Value: Codable & Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// Persists user settings as JSON values keyed by name.
public struct SettingsStore: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    /// The stored value, or the key's default when nothing is stored or the stored
    /// JSON no longer decodes (for example after a setting changed type).
    public func value<Value>(for key: SettingKey<Value>) async throws -> Value {
        let name = key.name
        let stored = try await database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [name])
        }
        guard let stored, let decoded = try? JSONDecoder().decode(Value.self, from: Data(stored.utf8)) else {
            return key.defaultValue
        }
        return decoded
    }

    public func set<Value>(_ value: Value, for key: SettingKey<Value>, now: Date = Date()) async throws {
        let name = key.name
        // JSONEncoder always produces valid UTF-8, so the non-failable conversion is exact.
        // swiftlint:disable:next optional_data_string_conversion
        let json = try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO setting (key, value, updatedAt) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
                """,
                arguments: [name, json, now]
            )
        }
    }

    /// Removes the stored value so the key reads as its default again.
    public func reset(_ key: SettingKey<some Codable & Sendable>) async throws {
        let name = key.name
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [name])
        }
    }
}
