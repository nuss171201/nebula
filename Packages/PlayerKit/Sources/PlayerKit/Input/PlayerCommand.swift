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
    case stepFrameForward
    case stepFrameBackward
    case speedUp
    case slowDown
    case resetSpeed
    case nextChapter
    case previousChapter
    /// Next or previous item in the queue.
    case playNext
    case playPrevious
    case cycleABLoop
    case toggleSubtitles
    /// Seconds; positive delays the sound.
    case shiftAudioDelay(Double)
    case shiftSubtitleDelay(Double)
    case cycleTrack(MediaTrack.Kind)
    /// Saves the current frame.
    case screenshot(includingSubtitles: Bool)
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
        KeyChord(.character(".")): .stepFrameForward,
        KeyChord(.character(",")): .stepFrameBackward,
        KeyChord(.character("]")): .speedUp,
        KeyChord(.character("[")): .slowDown,
        KeyChord(.character("0")): .resetSpeed,
        KeyChord(.rightArrow, .command): .nextChapter,
        KeyChord(.leftArrow, .command): .previousChapter,
        KeyChord(.rightArrow, [.command, .shift]): .playNext,
        KeyChord(.leftArrow, [.command, .shift]): .playPrevious,
        KeyChord(.character("l")): .cycleABLoop,
        KeyChord(.character("v")): .toggleSubtitles,
        KeyChord(.character("a")): .cycleTrack(.audio),
        KeyChord(.character("s")): .cycleTrack(.subtitle),
        KeyChord(.character("x")): .shiftSubtitleDelay(0.1),
        KeyChord(.character("z")): .shiftSubtitleDelay(-0.1),
        KeyChord(.character("x"), .shift): .shiftAudioDelay(0.1),
        KeyChord(.character("z"), .shift): .shiftAudioDelay(-0.1),
        KeyChord(.character("s"), .command): .screenshot(includingSubtitles: true),
        KeyChord(.character("s"), [.command, .shift]): .screenshot(includingSubtitles: false),
    ])
}
