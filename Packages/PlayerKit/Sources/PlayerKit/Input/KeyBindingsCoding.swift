import Foundation

/// Key chords and commands as short text, so that bindings can be stored in settings, shown
/// in an editor and (later) read from an `input.conf`: `cmd+shift+s`, `seek:-5`.
public extension KeyChord {
    private static let namedKeys: [(name: String, key: Key)] = [
        ("space", .space), ("left", .leftArrow), ("right", .rightArrow), ("up", .upArrow), ("down", .downArrow),
        ("esc", .escape), ("return", .returnKey),
    ]

    /// Modifiers in a fixed order, then the key: `ctrl+opt+shift+cmd+k`.
    var text: String {
        var parts: [String] = []
        if modifiers.contains(.control) {
            parts.append("ctrl")
        }
        if modifiers.contains(.option) {
            parts.append("opt")
        }
        if modifiers.contains(.shift) {
            parts.append("shift")
        }
        if modifiers.contains(.command) {
            parts.append("cmd")
        }
        switch key {
        case let .character(character): parts.append(character == "+" ? "plus" : String(character))
        default: parts.append(Self.namedKeys.first { $0.key == key }?.name ?? "?")
        }
        return parts.joined(separator: "+")
    }

    init?(text: String) {
        var modifiers: Modifiers = []
        var key: Key?
        for part in text.lowercased().split(separator: "+", omittingEmptySubsequences: true).map(String.init) {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd", "command", "meta": modifiers.insert(.command)
            case "plus": key = .character("+")
            default:
                guard key == nil else { return nil }
                if let named = Self.namedKeys.first(where: { $0.name == part }) {
                    key = named.key
                } else if part.count == 1, let character = part.first {
                    key = .character(character)
                } else {
                    return nil
                }
            }
        }
        guard let key else { return nil }
        self.init(key, modifiers)
    }
}

public extension PlayerCommand {
    private static let plain: [(name: String, command: PlayerCommand)] = [
        ("pause", .togglePause), ("mute", .toggleMute), ("fullscreen", .toggleFullScreen), ("exit-fullscreen", .exitFullScreen),
        ("frame-step", .stepFrameForward), ("frame-back-step", .stepFrameBackward),
        ("speed-up", .speedUp), ("speed-down", .slowDown), ("speed-reset", .resetSpeed),
        ("chapter-next", .nextChapter), ("chapter-previous", .previousChapter),
        ("queue-next", .playNext), ("queue-previous", .playPrevious),
        ("ab-loop", .cycleABLoop), ("subtitles", .toggleSubtitles),
        ("cycle-audio", .cycleTrack(.audio)), ("cycle-subtitles", .cycleTrack(.subtitle)), ("cycle-video", .cycleTrack(.video)),
        ("screenshot", .screenshot(includingSubtitles: true)), ("screenshot-video", .screenshot(includingSubtitles: false)),
        ("settings:video", .toggleSettings(.video)), ("settings:audio", .toggleSettings(.audio)),
        ("settings:subtitles", .toggleSettings(.subtitles)),
        ("picture-in-picture", .togglePictureInPicture), ("mini-player", .toggleMiniPlayer), ("always-on-top", .toggleAlwaysOnTop),
        ("close", .closePlayer),
    ]

    /// A stable name for the command, with its amount where it has one: `seek:-5`, `volume:5`.
    /// `nil` for commands that make no sense on a key (an absolute seek, an explicit pause state).
    var identifier: String? {
        switch self {
        case let .seekBy(seconds): "seek:\(Self.number(seconds))"
        case let .changeVolumeBy(amount): "volume:\(Self.number(amount))"
        case let .shiftAudioDelay(seconds): "audio-delay:\(Self.number(seconds))"
        case let .shiftSubtitleDelay(seconds): "subtitle-delay:\(Self.number(seconds))"
        default: Self.plain.first { $0.command == self }?.name
        }
    }

    init?(identifier: String) {
        if let match = Self.plain.first(where: { $0.name == identifier }) {
            self = match.command
            return
        }
        let parts = identifier.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let amount = Double(parts[1]), amount.isFinite else { return nil }
        switch parts[0] {
        case "seek": self = .seekBy(amount)
        case "volume": self = .changeVolumeBy(amount)
        case "audio-delay": self = .shiftAudioDelay(amount)
        case "subtitle-delay": self = .shiftSubtitleDelay(amount)
        default: return nil
        }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

public extension KeyBindings {
    /// What marks a key as deliberately unbound in stored overrides.
    static let unbound = "none"

    /// These bindings with the user's changes on top: each entry maps a chord's text to a
    /// command's identifier, or to `none` to unbind it. Entries that cannot be read are skipped.
    func applying(overrides: [String: String]) -> KeyBindings {
        var commands = commands
        // In a fixed order, so that two spellings of one chord always resolve the same way.
        for (chordText, commandText) in overrides.sorted(by: { $0.key < $1.key }) {
            guard let chord = KeyChord(text: chordText) else { continue }
            if commandText == Self.unbound {
                commands[chord] = nil
            } else if let command = PlayerCommand(identifier: commandText) {
                commands[chord] = command
            }
        }
        return KeyBindings(commands: commands)
    }

    /// The smallest set of overrides that turns `base` into these bindings.
    func overrides(comparedTo base: KeyBindings) -> [String: String] {
        var overrides: [String: String] = [:]
        for (chord, command) in commands where base.commands[chord] != command {
            if let identifier = command.identifier {
                overrides[chord.text] = identifier
            }
        }
        for chord in base.commands.keys where commands[chord] == nil {
            overrides[chord.text] = Self.unbound
        }
        return overrides
    }
}
