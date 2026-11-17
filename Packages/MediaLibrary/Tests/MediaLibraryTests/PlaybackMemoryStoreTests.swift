import Foundation
import GRDB
@testable import MediaLibrary
import Testing

@Suite("Playback memory")
struct PlaybackMemoryStoreTests {
    private struct Choice: Codable, Equatable {
        var audio: String
        var subtitlesOn: Bool
    }

    @Test("A value stored under several keys is found through any of them, most specific first")
    func lookupOrder() async throws {
        let store = try PlaybackMemoryStore(database: .inMemory())
        #expect(try await store.value(forAnyOf: ["file:a", "folder:x"], as: Choice.self) == nil)

        try await store.set(Choice(audio: "en", subtitlesOn: false), for: ["file:a", "folder:x"])
        try await store.set(Choice(audio: "ja", subtitlesOn: true), for: ["file:b"])

        #expect(try await store.value(forAnyOf: ["file:a", "folder:x"]) == Choice(audio: "en", subtitlesOn: false))
        // A sibling file has nothing of its own and inherits the folder's value.
        #expect(try await store.value(forAnyOf: ["file:c", "folder:x"]) == Choice(audio: "en", subtitlesOn: false))
        // Its own value wins over the folder's.
        #expect(try await store.value(forAnyOf: ["file:b", "folder:x"]) == Choice(audio: "ja", subtitlesOn: true))
        #expect(try await store.value(forAnyOf: [], as: Choice.self) == nil)
    }

    @Test("Storing again replaces, and removing forgets")
    func replaceAndRemove() async throws {
        let store = try PlaybackMemoryStore(database: .inMemory())
        try await store.set(Choice(audio: "en", subtitlesOn: false), for: ["series:1"])
        try await store.set(Choice(audio: "de", subtitlesOn: true), for: ["series:1"])
        #expect(try await store.value(forAnyOf: ["series:1"]) == Choice(audio: "de", subtitlesOn: true))

        try await store.remove(keys: ["series:1", "missing"])
        #expect(try await store.value(forAnyOf: ["series:1"], as: Choice.self) == nil)
    }

    @Test("A value that no longer decodes is skipped in favour of the next key")
    func unreadableValue() async throws {
        let database = try LibraryDatabase.inMemory()
        let store = PlaybackMemoryStore(database: database)
        try await store.set(["unexpected", "shape"], for: ["file:a"])
        try await store.set(Choice(audio: "en", subtitlesOn: true), for: ["folder:x"])
        #expect(try await store.value(forAnyOf: ["file:a", "folder:x"]) == Choice(audio: "en", subtitlesOn: true))
    }
}
