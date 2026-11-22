import Foundation
@testable import MediaLibrary
import Testing

struct DownloadStoreTests {
    private struct Row: Codable, Sendable, Equatable {
        var name: String
        var bytes: Int
    }

    private struct NewerRow: Codable, Sendable, Equatable {
        var name: String
        var bytes: Int
        var somethingNew: Bool
    }

    @Test("Downloads are listed in the order they were added, and saving one again keeps its place")
    func orderAndReplacement() async throws {
        let store = try DownloadStore(database: .inMemory())
        let start = Date(timeIntervalSince1970: 1000)
        try await store.save(Row(name: "first", bytes: 0), id: "a", now: start)
        try await store.save(Row(name: "second", bytes: 0), id: "b", now: start.addingTimeInterval(1))
        try await store.save(Row(name: "first", bytes: 512), id: "a", now: start.addingTimeInterval(2))

        #expect(try await store.all(as: Row.self) == [Row(name: "first", bytes: 512), Row(name: "second", bytes: 0)])
    }

    @Test("A removed download is gone; removing one that is not there does nothing")
    func removal() async throws {
        let store = try DownloadStore(database: .inMemory())
        try await store.save(Row(name: "only", bytes: 1), id: "a")
        try await store.remove(id: "missing")
        #expect(try await store.all(as: Row.self).count == 1)
        try await store.remove(id: "a")
        #expect(try await store.all(as: Row.self).isEmpty)
    }

    @Test("A row another version wrote, which cannot be read, is left out and the rest are kept")
    func unreadableRows() async throws {
        let store = try DownloadStore(database: .inMemory())
        try await store.save(Row(name: "old shape", bytes: 1), id: "a", now: Date(timeIntervalSince1970: 1))
        try await store.save(NewerRow(name: "new shape", bytes: 2, somethingNew: true), id: "b", now: Date(timeIntervalSince1970: 2))

        #expect(try await store.all(as: NewerRow.self) == [NewerRow(name: "new shape", bytes: 2, somethingNew: true)])
        #expect(try await store.all(as: Row.self).map(\.name) == ["old shape", "new shape"])
    }
}
