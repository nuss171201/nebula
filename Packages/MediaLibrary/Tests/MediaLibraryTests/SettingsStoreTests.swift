import Foundation
@testable import MediaLibrary
import Testing

@Suite("Settings persistence")
struct SettingsStoreTests {
    private static let cacheLimit = SettingKey<Int>("engine.cacheLimitGB", default: 10)
    private static let languages = SettingKey<[String]>("player.audioLanguages", default: ["en"])

    @Test("A fresh database has the schema applied")
    func migrations() async throws {
        let database = try LibraryDatabase.inMemory()
        #expect(try await database.appliedMigrations() == ["v1-settings", "v2-addons", "v3-playback-memory"])
    }

    @Test("Unset keys read as their default")
    func defaults() async throws {
        let store = try SettingsStore(database: .inMemory())
        #expect(try await store.value(for: Self.cacheLimit) == 10)
        #expect(try await store.value(for: Self.languages) == ["en"])
    }

    @Test("Values round-trip, overwrite, and reset")
    func roundTrip() async throws {
        let store = try SettingsStore(database: .inMemory())

        try await store.set(25, for: Self.cacheLimit)
        try await store.set(["hi", "en"], for: Self.languages)
        #expect(try await store.value(for: Self.cacheLimit) == 25)
        #expect(try await store.value(for: Self.languages) == ["hi", "en"])

        try await store.set(50, for: Self.cacheLimit)
        #expect(try await store.value(for: Self.cacheLimit) == 50)

        try await store.reset(Self.cacheLimit)
        #expect(try await store.value(for: Self.cacheLimit) == 10)
    }

    @Test("A stored value of the wrong type reads as the default instead of throwing")
    func typeChange() async throws {
        let store = try SettingsStore(database: .inMemory())
        try await store.set("ten", for: SettingKey<String>("engine.cacheLimitGB", default: ""))
        #expect(try await store.value(for: Self.cacheLimit) == 10)
    }

    @Test("Data survives closing and reopening the file, and migrations do not re-run")
    func persistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLibraryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("nested/library.sqlite")

        do {
            let store = try SettingsStore(database: LibraryDatabase(fileURL: fileURL))
            try await store.set(42, for: Self.cacheLimit)
        }

        let reopened = try LibraryDatabase(fileURL: fileURL)
        #expect(try await reopened.appliedMigrations() == ["v1-settings", "v2-addons", "v3-playback-memory"])
        #expect(try await SettingsStore(database: reopened).value(for: Self.cacheLimit) == 42)
    }
}
