import Foundation
import GRDB

/// The app's SQLite database. Owns the connection and the schema migrations;
/// feature stores (`SettingsStore`, and later library/history/add-on stores) share it.
public struct LibraryDatabase: Sendable {
    let writer: any DatabaseWriter

    /// Opens (creating if needed) the database file and brings its schema up to date.
    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: fileURL.path)
        try self.init(writer: pool)
    }

    /// A private in-memory database, for tests and previews.
    public static func inMemory() throws -> LibraryDatabase {
        try LibraryDatabase(writer: DatabaseQueue())
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Names of the migrations that have been applied, in order.
    public func appliedMigrations() async throws -> [String] {
        try await writer.read { db in
            try Self.migrator.appliedMigrations(db)
        }
    }

    /// Schema history. Migrations are append-only: never edit one that has shipped.
    ///
    /// Rows that will be synced across devices carry `updatedAt` so a future sync
    /// layer can resolve conflicts by last-writer-wins without a schema change.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-settings") { db in
            try db.create(table: "setting") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2-addons") { db in
            try db.create(table: "addon") { table in
                // The manifest URL: two configurations of one add-on are separate rows.
                table.primaryKey("address", .text)
                table.column("manifest", .text).notNull()
                table.column("position", .integer).notNull()
                table.column("isEnabled", .boolean).notNull().defaults(to: true)
                table.column("installedAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
        }

        return migrator
    }
}
