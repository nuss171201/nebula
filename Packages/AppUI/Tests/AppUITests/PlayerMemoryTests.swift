@testable import AppUI
import Foundation
import MediaLibrary
import PlayerKit
import Testing

@Suite("The player's memory in the app's database")
struct LibraryPlayerMemoryTests {
    private func makeMemory() throws -> LibraryPlayerMemory {
        let database = try LibraryDatabase.inMemory()
        return LibraryPlayerMemory(store: PlaybackMemoryStore(database: database), settings: SettingsStore(database: database))
    }

    @Test("Positions are stored per file and can be forgotten")
    func positions() async throws {
        let memory = try makeMemory()
        #expect(await memory.rememberedPosition(for: "file:/films/a.mkv") == nil)
        await memory.remember(.at(1234.5), duration: nil, for: "file:/films/a.mkv")
        await memory.remember(.at(60), duration: nil, for: "file:/films/b.mkv")
        #expect(await memory.rememberedPosition(for: "file:/films/a.mkv") == 1234.5)
        #expect(await memory.rememberedPosition(for: "file:/films/b.mkv") == 60)

        await memory.remember(.finished, duration: nil, for: "file:/films/a.mkv")
        #expect(await memory.rememberedPosition(for: "file:/films/a.mkv") == nil)
        #expect(await memory.rememberedPosition(for: "file:/films/b.mkv") == 60)
    }

    @Test("A position and a track choice for the same file do not disturb each other")
    func separateFromTracks() async throws {
        let memory = try makeMemory()
        let tracks = RememberedTracks(audio: TrackDescriptor(language: "fra"))
        await memory.remember(tracks, for: ["file:/films/a.mkv"])
        await memory.remember(.at(90), duration: nil, for: "file:/films/a.mkv")
        #expect(await memory.rememberedTracks(forAnyOf: ["file:/films/a.mkv"]) == tracks)
        await memory.remember(.finished, duration: nil, for: "file:/films/a.mkv")
        #expect(await memory.rememberedTracks(forAnyOf: ["file:/films/a.mkv"]) == tracks)
    }
}
