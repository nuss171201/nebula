import Foundation
import GRDB
import MediaCore

/// Persists the user's installed add-ons and their order.
public struct AddonStore: Sendable {
    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    /// Installed add-ons in the user's order. A row whose stored manifest can no
    /// longer be read is skipped rather than failing the whole list.
    public func all() async throws -> [InstalledAddon] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT address, manifest, isEnabled FROM addon ORDER BY position, installedAt"
            )
            return rows.compactMap { row in
                let address: String = row["address"]
                let manifestJSON: String = row["manifest"]
                guard let transport = try? AddonTransportURL(userInput: address),
                      let manifest = try? JSONDecoder().decode(AddonManifest.self, from: Data(manifestJSON.utf8))
                else { return nil }
                return InstalledAddon(address: transport, manifest: manifest, isEnabled: row["isEnabled"])
            }
        }
    }

    /// Adds an add-on at the end of the list. Installing an address that is already
    /// present refreshes its manifest and keeps its position and enabled state.
    public func install(_ addon: InstalledAddon, now: Date = Date()) async throws {
        let address = addon.id
        let manifest = try Self.encode(addon.manifest)
        let isEnabled = addon.isEnabled
        try await database.writer.write { db in
            let nextPosition = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM addon") ?? 0
            try db.execute(
                sql: """
                INSERT INTO addon (address, manifest, position, isEnabled, installedAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(address) DO UPDATE SET manifest = excluded.manifest, updatedAt = excluded.updatedAt
                """,
                arguments: [address, manifest, nextPosition, isEnabled, now, now]
            )
        }
    }

    /// Replaces the stored manifest of an installed add-on. Does nothing if it is not installed.
    public func updateManifest(_ manifest: AddonManifest, forAddonID id: String, now: Date = Date()) async throws {
        let json = try Self.encode(manifest)
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE addon SET manifest = ?, updatedAt = ? WHERE address = ?",
                arguments: [json, now, id]
            )
        }
    }

    public func remove(addonID id: String) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM addon WHERE address = ?", arguments: [id])
        }
    }

    public func setEnabled(_ isEnabled: Bool, addonID id: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE addon SET isEnabled = ?, updatedAt = ? WHERE address = ?",
                arguments: [isEnabled, now, id]
            )
        }
    }

    /// Stores a new order. Ids not mentioned keep their relative order after the listed ones.
    public func reorder(addonIDs ids: [String], now: Date = Date()) async throws {
        try await database.writer.write { db in
            let existing = try String.fetchAll(db, sql: "SELECT address FROM addon ORDER BY position, installedAt")
            let listed = ids.filter(existing.contains)
            let ordered = listed + existing.filter { !listed.contains($0) }
            for (position, id) in ordered.enumerated() {
                try db.execute(
                    sql: "UPDATE addon SET position = ?, updatedAt = ? WHERE address = ?",
                    arguments: [position, now, id]
                )
            }
        }
    }

    private static func encode(_ manifest: AddonManifest) throws -> String {
        // JSONEncoder always produces valid UTF-8, so the non-failable conversion is exact.
        // swiftlint:disable:next optional_data_string_conversion
        try String(decoding: JSONEncoder().encode(manifest), as: UTF8.self)
    }
}
