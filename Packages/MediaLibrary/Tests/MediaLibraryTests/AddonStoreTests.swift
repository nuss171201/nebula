import Foundation
import GRDB
import MediaCore
@testable import MediaLibrary
import Testing

@Suite("Installed add-ons persistence")
struct AddonStoreTests {
    private func addon(_ host: String, name: String? = nil, catalogs: Int = 0) throws -> InstalledAddon {
        try InstalledAddon(
            address: AddonTransportURL(userInput: "https://\(host)/manifest.json"),
            manifest: AddonManifest(
                id: "id.\(host)",
                name: name ?? host,
                types: [.movie],
                resources: [ManifestResource(name: "catalog")],
                catalogs: (0 ..< catalogs).map { ManifestCatalog(type: .movie, id: "c\($0)") }
            )
        )
    }

    @Test("Installed add-ons come back in install order with their manifests intact")
    func installAndList() async throws {
        let store = try AddonStore(database: .inMemory())
        #expect(try await store.all().isEmpty)

        let first = try addon("a.example.com", catalogs: 2)
        let second = try addon("b.example.com")
        try await store.install(first)
        try await store.install(second)

        let all = try await store.all()
        #expect(all == [first, second])
        #expect(all[0].manifest.catalogs.count == 2)
    }

    @Test("Re-installing refreshes the manifest but keeps position and enabled state")
    func reinstall() async throws {
        let store = try AddonStore(database: .inMemory())
        let first = try addon("a.example.com", name: "Old name")
        try await store.install(first)
        try await store.install(addon("b.example.com"))
        try await store.setEnabled(false, addonID: first.id)

        try await store.install(addon("a.example.com", name: "New name"))

        let all = try await store.all()
        #expect(all.map(\.manifest.name) == ["New name", "b.example.com"])
        #expect(all[0].isEnabled == false)
    }

    @Test("Enable, disable, update and remove")
    func mutations() async throws {
        let store = try AddonStore(database: .inMemory())
        let first = try addon("a.example.com")
        let second = try addon("b.example.com")
        try await store.install(first)
        try await store.install(second)

        try await store.setEnabled(false, addonID: second.id)
        #expect(try await store.all().map(\.isEnabled) == [true, false])

        var updated = first.manifest
        updated.version = "9.9.9"
        try await store.updateManifest(updated, forAddonID: first.id)
        #expect(try await store.all().first?.manifest.version == "9.9.9")

        try await store.remove(addonID: first.id)
        #expect(try await store.all().map(\.id) == [second.id])

        try await store.remove(addonID: "https://missing.example.com/manifest.json")
        #expect(try await store.all().count == 1)
    }

    @Test("Reordering stores the new order; unlisted add-ons stay at the end")
    func reorder() async throws {
        let store = try AddonStore(database: .inMemory())
        let addons = try ["a", "b", "c", "d"].map { try addon("\($0).example.com") }
        for addon in addons {
            try await store.install(addon)
        }

        try await store.reorder(addonIDs: [addons[2].id, addons[0].id, "https://unknown.example.com/manifest.json"])
        #expect(try await store.all().map(\.manifest.name) == [
            "c.example.com", "a.example.com", "b.example.com", "d.example.com",
        ])

        // A newly installed add-on still lands at the end after a reorder.
        try await store.install(addon("e.example.com"))
        #expect(try await store.all().last?.manifest.name == "e.example.com")
    }

    @Test("A row with an unreadable manifest is skipped")
    func corruptRow() async throws {
        let database = try LibraryDatabase.inMemory()
        let store = AddonStore(database: database)
        try await store.install(addon("good.example.com"))
        try await database.writer.write { db in
            try db.execute(
                sql: "INSERT INTO addon (address, manifest, position, isEnabled, installedAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["https://bad.example.com/manifest.json", "{not json", 5, true, Date(), Date()]
            )
        }
        #expect(try await store.all().map(\.manifest.name) == ["good.example.com"])
    }
}
