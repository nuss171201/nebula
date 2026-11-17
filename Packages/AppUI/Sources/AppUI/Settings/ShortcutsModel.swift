import Foundation
import MediaLibrary
import Observation
import PlayerKit

/// The player's keyboard shortcuts: what is bound to what, and the user's changes to it.
///
/// Three layers, each on top of the one before: the standard bindings, an `input.conf` if
/// there is one, and what the user changed here. Only the last is stored.
@MainActor
@Observable
public final class ShortcutsModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public var action: ShortcutAction
        public var chords: [KeyChord]
        /// Whether its keys differ from the ones it has without the user's changes.
        public var isChanged: Bool

        public var id: String { action.id }
    }

    public struct Group: Identifiable, Equatable, Sendable {
        public var title: String
        public var rows: [Row]

        public var id: String { title }
    }

    /// Every action that can have a key, with its keys, grouped as the editor shows them.
    public private(set) var groups: [Group] = []
    /// What the last change did besides what was asked ("⌘K was taken from Mute"), or why it was refused.
    public private(set) var notice: String?
    /// The action waiting for a key press, if the editor is recording one.
    public var recordingActionID: String?
    public private(set) var hasChanges = false

    /// The bindings in effect.
    @ObservationIgnored public private(set) var bindings = KeyBindings.standard
    @ObservationIgnored private var overrides: [String: String] = [:]
    @ObservationIgnored private var fileBindings: [KeyChord: PlayerCommand?] = [:]
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let coordinator: PlayerCoordinator
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Chords the app's menus and the system use; a player binding for them would never be reached.
    static let reserved: [KeyChord: String] = [
        KeyChord(.character("q"), .command): "quitting the app",
        KeyChord(.character("w"), .command): "closing the window",
        KeyChord(.character("h"), .command): "hiding the app",
        KeyChord(.character("m"), .command): "minimising the window",
        KeyChord(.character(","), .command): "opening Settings",
        KeyChord(.character("o"), .command): "opening a file",
        KeyChord(.character("o"), [.command, .shift]): "opening a location",
        KeyChord(.character("f"), [.command, .control]): "full screen in the Window menu",
    ]

    public init(store: SettingsStore, coordinator: PlayerCoordinator) {
        self.store = store
        self.coordinator = coordinator
        rebuild()
    }

    /// Reads the stored changes. Call once, at launch.
    public func load() async {
        overrides = await (try? store.value(for: LibraryPlayerMemory.keyBindingOverridesKey)) ?? [:]
        rebuild()
    }

    /// The bindings of an `input.conf`, or none.
    public func setFileBindings(_ bindings: [KeyChord: PlayerCommand?]) {
        guard bindings != fileBindings else { return }
        fileBindings = bindings
        rebuild()
    }

    // MARK: - Editing

    /// Starts or stops waiting for a key press for an action.
    public func toggleRecording(for action: ShortcutAction) {
        recordingActionID = recordingActionID == action.id ? nil : action.id
        notice = nil
    }

    /// A key was pressed while recording. Escape alone cancels. Returns whether the press was used.
    @discardableResult
    public func record(_ chord: KeyChord) -> Bool {
        guard let id = recordingActionID, let action = groups.flatMap(\.rows).first(where: { $0.id == id })?.action else { return false }
        recordingActionID = nil
        guard chord != KeyChord(.escape) else { return true }
        assign(chord, to: action)
        return true
    }

    /// Gives a chord to an action, taking it from whatever had it. Returns whether it was accepted.
    @discardableResult
    public func assign(_ chord: KeyChord, to action: ShortcutAction) -> Bool {
        if let use = Self.reserved[chord] {
            notice = "\(chord.displayText) is used for \(use) and cannot be a player shortcut."
            return false
        }
        let previous = bindings.command(for: chord)
        guard previous != action.command else {
            notice = nil
            return true
        }
        var commands = bindings.commands
        commands[chord] = action.command
        notice = previous.flatMap(ShortcutAction.describing).map { "\(chord.displayText) was taken from “\($0.title)”." }
        commit(KeyBindings(commands: commands))
        return true
    }

    public func remove(_ chord: KeyChord) {
        var commands = bindings.commands
        guard commands.removeValue(forKey: chord) != nil else { return }
        notice = nil
        commit(KeyBindings(commands: commands))
    }

    /// Gives an action back the keys it has without the user's changes. A key of its own that
    /// the user has since given to something else stays where the user put it.
    public func reset(_ action: ShortcutAction) {
        let base = base
        var commands = bindings.commands
        for (chord, command) in commands where command == action.command && base.commands[chord] != command {
            commands[chord] = base.commands[chord]
        }
        for (chord, command) in base.commands where command == action.command && commands[chord] == nil {
            commands[chord] = command
        }
        notice = nil
        commit(KeyBindings(commands: commands))
    }

    public func resetAll() {
        notice = nil
        recordingActionID = nil
        commit(base)
    }

    /// Waits for the last change to be stored. For tests.
    func waitForSave() async {
        await saveTask?.value
    }

    // MARK: - Internals

    /// The bindings without the user's changes.
    private var base: KeyBindings {
        KeyBindings.standard.applying(fileBindings)
    }

    private func commit(_ bindings: KeyBindings) {
        overrides = bindings.overrides(comparedTo: base)
        rebuild()
        let overrides = overrides
        // One after another, so that the last change is the one that stays.
        saveTask = Task { [store, previous = saveTask] in
            await previous?.value
            try? await store.set(overrides, for: LibraryPlayerMemory.keyBindingOverridesKey)
        }
    }

    private func rebuild() {
        let base = base
        bindings = base.applying(overrides: overrides)
        coordinator.keyBindings = bindings
        hasChanges = bindings != base

        var chordsByCommand: [PlayerCommand: [KeyChord]] = [:]
        for (chord, command) in bindings.commands {
            chordsByCommand[command, default: []].append(chord)
        }
        var baseChordsByCommand: [PlayerCommand: Set<KeyChord>] = [:]
        for (chord, command) in base.commands {
            baseChordsByCommand[command, default: []].insert(chord)
        }
        // The listed actions, then whatever else is bound (a bindings file can bind more).
        var actions = ShortcutAction.all
        let listed = Set(actions.map(\.command))
        let extras = Set(bindings.commands.values).union(base.commands.values).subtracting(listed)
        actions += extras.compactMap(ShortcutAction.describing).sorted { $0.title < $1.title }

        var groups: [Group] = []
        for action in actions {
            let chords = (chordsByCommand[action.command] ?? []).sorted { Self.order($0) < Self.order($1) }
            let row = Row(action: action, chords: chords, isChanged: Set(chords) != baseChordsByCommand[action.command] ?? [])
            if let index = groups.firstIndex(where: { $0.title == action.group }) {
                groups[index].rows.append(row)
            } else {
                groups.append(Group(title: action.group, rows: [row]))
            }
        }
        self.groups = groups
    }

    /// Fewer modifiers first, then by name, so the order does not jump about between changes.
    private static func order(_ chord: KeyChord) -> String {
        "\(chord.modifiers.rawValue.nonzeroBitCount)\(chord.text)"
    }
}
