/// Something the user can ask the player to do, independent of which key or control asked.
public enum PlayerCommand: Hashable, Sendable {
    case togglePause
    /// Seconds; negative goes back.
    case seekBy(Double)
    /// Volume points on the 0–100 scale; negative lowers.
    case changeVolumeBy(Double)
    case toggleMute
    case toggleFullScreen
    case exitFullScreen
}

/// A key press: which key, and which modifier keys were held.
public struct KeyChord: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case space, leftArrow, rightArrow, upArrow, downArrow, escape, returnKey
        /// A printable key, lower-cased.
        case character(Character)
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

/// Which key does what in the player window. A plain table so it can later be loaded
/// from the user's settings and `input.conf`.
public struct KeyBindings: Sendable, Equatable {
    public var commands: [KeyChord: PlayerCommand]

    public init(commands: [KeyChord: PlayerCommand]) {
        self.commands = commands
    }

    public func command(for chord: KeyChord) -> PlayerCommand? {
        commands[chord]
    }

    public static let standard = KeyBindings(commands: [
        KeyChord(.space): .togglePause,
        KeyChord(.character("k")): .togglePause,
        KeyChord(.leftArrow): .seekBy(-5),
        KeyChord(.rightArrow): .seekBy(5),
        KeyChord(.leftArrow, .shift): .seekBy(-30),
        KeyChord(.rightArrow, .shift): .seekBy(30),
        KeyChord(.upArrow): .changeVolumeBy(5),
        KeyChord(.downArrow): .changeVolumeBy(-5),
        KeyChord(.character("m")): .toggleMute,
        KeyChord(.character("f")): .toggleFullScreen,
        KeyChord(.returnKey): .toggleFullScreen,
        KeyChord(.escape): .exitFullScreen,
    ])
}
