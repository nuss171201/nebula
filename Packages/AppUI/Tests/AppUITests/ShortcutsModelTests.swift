@testable import AppUI
import Foundation
import MediaLibrary
import PlayerKit
import Testing

@MainActor
@Suite("Shortcut editor")
struct ShortcutsModelTests {
    private func row(_ model: ShortcutsModel, _ title: String) -> ShortcutsModel.Row? {
        model.groups.flatMap(\.rows).first { $0.action.title == title }
    }

    private func action(_ title: String) throws -> ShortcutAction {
        try #require(ShortcutAction.all.first { $0.title == title })
    }

    @Test("It starts with the standard keys, grouped")
    func standard() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        await model.load()
        #expect(model.groups.map(\.title) == ["Playback", "Navigation", "Sound", "Subtitles", "Window", "Other"])
        #expect(row(model, "Play / Pause")?.chords == [KeyChord(.character("k")), KeyChord(.space)])
        #expect(row(model, "Forward 30 Seconds")?.chords == [KeyChord(.rightArrow, .shift)])
        #expect(row(model, "Next Audio Track")?.isChanged == false)
        #expect(!model.hasChanges)
        #expect(model.bindings == .standard)
        await fixture.tearDown()
    }

    @Test("A new key is bound, reaches the player, and is there after a relaunch")
    func assign() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        await model.load()
        let mute = try action("Mute")
        #expect(model.assign(KeyChord(.character("u"), .control), to: mute))
        #expect(model.notice == nil)
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("m")), KeyChord(.character("u"), .control)])
        #expect(row(model, "Mute")?.isChanged == true)
        #expect(model.hasChanges)
        #expect(fixture.coordinator.keyBindings.command(for: KeyChord(.character("u"), .control)) == .toggleMute)
        await model.waitForSave()

        let next = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        await next.load()
        #expect(next.bindings.command(for: KeyChord(.character("u"), .control)) == .toggleMute)
        #expect(next.hasChanges)
        await fixture.tearDown()
    }

    @Test("A key that is taken moves, and the editor says from where; the app's own keys are refused")
    func conflicts() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        let mute = try action("Mute")
        #expect(model.assign(KeyChord(.character("f")), to: mute))
        #expect(model.notice == "F was taken from “Full Screen”.")
        #expect(row(model, "Full Screen")?.chords == [KeyChord(.returnKey)])
        #expect(row(model, "Full Screen")?.isChanged == true)
        #expect(model.bindings.command(for: KeyChord(.character("f"))) == .toggleMute)

        // Assigning what it already has changes nothing and says nothing.
        #expect(model.assign(KeyChord(.character("m")), to: mute))
        #expect(model.notice == nil)

        #expect(!model.assign(KeyChord(.character("q"), .command), to: mute))
        #expect(model.notice == "⌘Q is used for quitting the app and cannot be a player shortcut.")
        #expect(model.bindings.command(for: KeyChord(.character("q"), .command)) == nil)
        await model.waitForSave()
        await fixture.tearDown()
    }

    @Test("Keys can be removed; one action or everything can be put back")
    func removeAndReset() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        let pause = try action("Play / Pause")
        let mute = try action("Mute")
        model.remove(KeyChord(.space))
        model.assign(KeyChord(.character("p")), to: pause)
        model.assign(KeyChord(.character("k")), to: mute)
        #expect(row(model, "Play / Pause")?.chords == [KeyChord(.character("p"))])

        // Space comes back and P goes; K stays with Mute, where the user put it.
        model.reset(pause)
        #expect(row(model, "Play / Pause")?.chords == [KeyChord(.space)])
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("k")), KeyChord(.character("m"))])
        #expect(model.hasChanges)

        model.resetAll()
        #expect(model.bindings == .standard)
        #expect(!model.hasChanges)
        await model.waitForSave()
        #expect(try await fixture.store.value(for: LibraryPlayerMemory.keyBindingOverridesKey).isEmpty)
        await fixture.tearDown()
    }

    @Test("Recording takes the next key press; Escape cancels")
    func recording() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        let mute = try action("Mute")
        #expect(!model.record(KeyChord(.character("j"))))

        model.toggleRecording(for: mute)
        #expect(model.recordingActionID == mute.id)
        #expect(model.record(KeyChord(.escape)))
        #expect(model.recordingActionID == nil)
        #expect(model.bindings == .standard)

        model.toggleRecording(for: mute)
        #expect(model.record(KeyChord(.character("j"))))
        #expect(model.recordingActionID == nil)
        #expect(model.bindings.command(for: KeyChord(.character("j"))) == .toggleMute)

        model.toggleRecording(for: mute)
        model.toggleRecording(for: mute)
        #expect(model.recordingActionID == nil)
        await model.waitForSave()
        await fixture.tearDown()
    }

    @Test("A bindings file sits under the user's changes and is what Reset goes back to")
    func fileLayer() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        let file = InputConfigFile.parse("g cycle mute\nRIGHT seek 10\nm ignore").bindings
        model.setFileBindings(file)
        #expect(!model.hasChanges)
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("g"))])
        // A command the editor does not list gets a row of its own.
        #expect(row(model, "Forward 10 Seconds")?.chords == [KeyChord(.rightArrow)])
        #expect(row(model, "Forward 5 Seconds")?.chords == [])

        let mute = try action("Mute")
        model.assign(KeyChord(.character("u")), to: mute)
        #expect(model.hasChanges)
        model.resetAll()
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("g"))])

        // Without the file the user's own changes remain.
        model.assign(KeyChord(.character("u")), to: mute)
        model.setFileBindings([:])
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("m")), KeyChord(.character("u"))])
        #expect(row(model, "Forward 10 Seconds") == nil)
        await model.waitForSave()
        await fixture.tearDown()
    }
}
