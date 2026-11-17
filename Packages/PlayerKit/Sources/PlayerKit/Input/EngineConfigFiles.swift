import Foundation

/// A line of a config file that was not used, and why.
public struct IgnoredConfigLine: Sendable, Equatable, Identifiable {
    /// Line number in the file, from 1.
    public var number: Int
    public var text: String
    public var reason: String

    public init(number: Int, text: String, reason: String) {
        self.number = number
        self.text = text
        self.reason = reason
    }

    public var id: Int { number }
}

/// Reads an `mpv.conf`: the playback engine's own options file, for people who have one or
/// want settings the app has no control for.
///
/// Only options are read (`name=value`, `name`, `no-name`). Options the app must keep
/// control of are left out, and so is anything that could run programs or write files:
/// the file is the user's, but it should not be able to do more than change how video plays.
public enum EngineConfigFile {
    public struct Result: Sendable, Equatable {
        public var options: [PlayerConfiguration.EngineOption] = []
        public var ignored: [IgnoredConfigLine] = []
    }

    /// Options the app sets itself or replaces with its own features.
    private static let controlledByApp: Set<String> = [
        "wid", "vo", "gpu-context", "gpu-api", "osc", "idle", "keep-open", "keep-open-pause", "terminal", "config", "config-dir",
        "force-window", "border", "ontop", "fullscreen", "fs", "geometry", "title", "cursor-autohide", "pause", "volume", "mute",
        "alang", "slang", "aid", "sid", "vid", "resume-playback", "save-position-on-quit", "loop-file", "loop-playlist", "loop",
        "ab-loop-a", "ab-loop-b", "start", "profile", "use-filedir-conf", "ytdl", "target-colorspace-hint", "really-quiet", "msg-level",
        "sub-auto", "sub-file-paths", "screenshot-directory", "screenshot-template", "screenshot-format",
        // The picture is laid out in a fixed canvas that the app scales; these would fight it.
        "keepaspect", "keepaspect-window", "video-unscaled", "panscan", "video-crop", "sub-use-margins", "sub-ass-force-margins",
        "speed", "chapter", "end", "length", "volume-max", "shuffle", "playlist-start",
    ]
    private static let controlledPrefixes = ["input-", "window-", "autofit", "watch-later", "osd-playing", "ytdl-", "load-", "macos-"]
    /// Options that reach beyond playback: other files, programs, sockets, recordings.
    private static let unsafe: Set<String> = [
        "include", "script", "scripts", "script-opts", "log-file", "dump-stats", "stream-record", "stream-dump", "record-file",
        "o", "of", "ovc", "oac", "ofopts", "ovcopts", "oacopts", "cookies-file", "sub-files", "audio-files", "external-files",
        "cover-art-files", "playlist", "icc-profile", "gpu-shader-cache-dir", "icc-cache-dir", "demuxer-cache-dir", "glsl-shaders",
        "glsl-shader", "vf", "af", "lavfi-complex", "opengl-dumb-mode", "ipc", "network-timeout-file",
    ]

    public static func parse(_ text: String) -> Result {
        var result = Result()
        var isInProfile = false
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            func ignore(_ reason: String) {
                result.ignored.append(IgnoredConfigLine(number: index + 1, text: line, reason: reason))
            }
            if line.hasPrefix("[") {
                isInProfile = true
                ignore("Profiles are not supported; what follows a profile heading is not read.")
                continue
            }
            guard !isInProfile else { continue }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            var name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            while name.hasPrefix("-") {
                name.removeFirst()
            }
            var value = parts.count > 1 ? unquote(parts[1].trimmingCharacters(in: .whitespaces)) : "yes"
            if parts.count == 1, name.hasPrefix("no-") {
                name.removeFirst(3)
                value = "no"
            }
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                ignore("This is not an option.")
                continue
            }
            if unsafe.contains(name) || name.hasPrefix("script") || name.hasPrefix("ao-pcm") {
                ignore("Options that read other files, run filters or scripts, or write files are not allowed here.")
            } else if controlledByApp.contains(name) || controlledPrefixes.contains(where: name.hasPrefix) {
                ignore("The app controls this itself.")
            } else {
                result.options.append(PlayerConfiguration.EngineOption(name, value))
            }
        }
        return result
    }

    /// Everything from a `#` that is at the start of the line or follows a space, outside quotes.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for index in line.indices {
            let character = line[index]
            if let open = quote {
                if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous == " " || previous == "\t" {
                return String(line[..<index])
            }
            previous = character
        }
        return line
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }
}

/// Reads an `input.conf`: the playback engine's key bindings file.
///
/// Keys and commands the player has its own form of are translated to it; the rest are left
/// out and listed. Nothing is passed to the engine as it stands, so a bindings file cannot
/// make the player do anything its own shortcuts could not.
public enum InputConfigFile {
    public struct Result: Sendable, Equatable {
        /// A chord bound to `nil` is deliberately unbound (`ignore`).
        public var bindings: [KeyChord: PlayerCommand?] = [:]
        public var ignored: [IgnoredConfigLine] = []
    }

    private static let commandPrefixes: Set<String> = [
        "no-osd", "osd-auto", "osd-bar", "osd-msg", "osd-msg-bar", "repeatable", "nonrepeatable", "async", "sync",
    ]

    public static func parse(_ text: String) -> Result {
        var result = Result()
        for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = EngineConfigFile.stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            func ignore(_ reason: String) {
                result.ignored.append(IgnoredConfigLine(number: index + 1, text: line, reason: reason))
            }
            // "{section}" prefixes and command prefixes such as "no-osd" say how, not what.
            var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                .filter { !($0.hasPrefix("{") && $0.hasSuffix("}")) && !commandPrefixes.contains($0) }
            guard !words.isEmpty, let chord = chord(named: words.removeFirst()) else {
                ignore("This key cannot be bound here.")
                continue
            }
            guard !words.isEmpty else {
                ignore("No command follows the key.")
                continue
            }
            if words[0] == "ignore" {
                result.bindings[chord] = PlayerCommand?.none
            } else if let command = command(for: words) {
                result.bindings[chord] = command
            } else {
                ignore("The player has no equivalent of this command.")
            }
        }
        return result
    }

    /// `SPACE`, `LEFT`, `Shift+RIGHT`, `ctrl+s`, `Q` (which is Shift+q).
    static func chord(named name: String) -> KeyChord? {
        var parts = name.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" itself as the key: "Ctrl++" ends in two empty parts.
        var keyText = parts.removeLast()
        if keyText.isEmpty, parts.last == "" {
            parts.removeLast()
            keyText = "+"
        }
        var modifiers: KeyChord.Modifiers = []
        for part in parts {
            switch part.lowercased() {
            case "ctrl": modifiers.insert(.control)
            case "alt": modifiers.insert(.option)
            case "meta": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        let named: [String: KeyChord.Key] = [
            "SPACE": .space, "LEFT": .leftArrow, "RIGHT": .rightArrow, "UP": .upArrow, "DOWN": .downArrow,
            "ESC": .escape, "ENTER": .returnKey, "KP_ENTER": .returnKey, "SHARP": .character("#"),
        ]
        if let key = named[keyText.uppercased()], keyText.count > 1 {
            return KeyChord(key, modifiers)
        }
        guard keyText.count == 1, let character = keyText.first else { return nil }
        if character.isLetter, character.isUppercase {
            modifiers.insert(.shift)
        }
        return KeyChord(.character(Character(character.lowercased())), modifiers)
    }

    static func command(for words: [String]) -> PlayerCommand? {
        let name = words[0]
        let first = words.count > 1 ? words[1] : nil
        let amount = words.count > 2 ? Double(words[2]) : nil
        switch (name, first) {
        case ("cycle", "pause"): return .togglePause
        case ("set", "pause"): return words.count > 2 ? .setPaused(words[2] == "yes") : nil
        case ("cycle", "mute"): return .toggleMute
        case ("cycle", "fullscreen"): return .toggleFullScreen
        case ("set", "fullscreen"): return words.count > 2 && words[2] == "no" ? .exitFullScreen : .toggleFullScreen
        case ("cycle", "ontop"): return .toggleAlwaysOnTop
        case ("cycle", "sub-visibility"): return .toggleSubtitles
        case ("cycle", "sub"), ("cycle", "sid"): return .cycleTrack(.subtitle)
        case ("cycle", "audio"), ("cycle", "aid"): return .cycleTrack(.audio)
        case ("cycle", "video"), ("cycle", "vid"): return .cycleTrack(.video)
        case ("add", "volume"): return amount.map(PlayerCommand.changeVolumeBy)
        case ("add", "sub-delay"): return amount.map(PlayerCommand.shiftSubtitleDelay)
        case ("add", "audio-delay"): return amount.map(PlayerCommand.shiftAudioDelay)
        case ("add", "chapter"): return amount.map { $0 >= 0 ? .nextChapter : .previousChapter }
        case ("add", "speed"): return amount.map { $0 >= 0 ? .speedUp : .slowDown }
        case ("multiply", "speed"): return amount.map { $0 >= 1 ? .speedUp : .slowDown }
        case ("set", "speed"): return amount == 1 ? .resetSpeed : nil
        case ("seek", _):
            // Only relative seeks have a key-sized meaning; "absolute" and percentages do not.
            guard let seconds = first.flatMap(Double.init), !words.dropFirst(2).contains(where: { $0.contains("absolute") }) else { return nil }
            return .seekBy(seconds)
        case ("frame-step", _): return .stepFrameForward
        case ("frame-back-step", _): return .stepFrameBackward
        case ("playlist-next", _): return .playNext
        case ("playlist-prev", _): return .playPrevious
        case ("ab-loop", _): return .cycleABLoop
        case ("screenshot", _): return .screenshot(includingSubtitles: first != "video")
        case ("quit", _), ("stop", _): return .closePlayer
        default: return nil
        }
    }
}

public extension KeyBindings {
    /// These bindings with those of a bindings file on top; a chord the file unbinds is removed.
    func applying(_ file: [KeyChord: PlayerCommand?]) -> KeyBindings {
        var commands = commands
        for (chord, command) in file {
            commands[chord] = command
        }
        return KeyBindings(commands: commands)
    }
}

/// A thing a key can be made to do, for the shortcut editor.
public struct ShortcutAction: Sendable, Hashable, Identifiable {
    public var title: String
    public var group: String
    public var command: PlayerCommand

    public var id: String { command.identifier ?? title }

    /// Everything that can be given a key, in the order the editor shows it.
    public static let all: [ShortcutAction] = [
        ShortcutAction(title: "Play / Pause", group: "Playback", command: .togglePause),
        ShortcutAction(title: "Forward 5 Seconds", group: "Playback", command: .seekBy(5)),
        ShortcutAction(title: "Back 5 Seconds", group: "Playback", command: .seekBy(-5)),
        ShortcutAction(title: "Forward 30 Seconds", group: "Playback", command: .seekBy(30)),
        ShortcutAction(title: "Back 30 Seconds", group: "Playback", command: .seekBy(-30)),
        ShortcutAction(title: "Next Frame", group: "Playback", command: .stepFrameForward),
        ShortcutAction(title: "Previous Frame", group: "Playback", command: .stepFrameBackward),
        ShortcutAction(title: "Faster", group: "Playback", command: .speedUp),
        ShortcutAction(title: "Slower", group: "Playback", command: .slowDown),
        ShortcutAction(title: "Normal Speed", group: "Playback", command: .resetSpeed),
        ShortcutAction(title: "Set A-B Loop Point", group: "Playback", command: .cycleABLoop),
        ShortcutAction(title: "Next Chapter", group: "Navigation", command: .nextChapter),
        ShortcutAction(title: "Previous Chapter", group: "Navigation", command: .previousChapter),
        ShortcutAction(title: "Next in Queue", group: "Navigation", command: .playNext),
        ShortcutAction(title: "Previous in Queue", group: "Navigation", command: .playPrevious),
        ShortcutAction(title: "Volume Up", group: "Sound", command: .changeVolumeBy(5)),
        ShortcutAction(title: "Volume Down", group: "Sound", command: .changeVolumeBy(-5)),
        ShortcutAction(title: "Mute", group: "Sound", command: .toggleMute),
        ShortcutAction(title: "Next Audio Track", group: "Sound", command: .cycleTrack(.audio)),
        ShortcutAction(title: "Sound Later", group: "Sound", command: .shiftAudioDelay(0.1)),
        ShortcutAction(title: "Sound Earlier", group: "Sound", command: .shiftAudioDelay(-0.1)),
        ShortcutAction(title: "Show or Hide Subtitles", group: "Subtitles", command: .toggleSubtitles),
        ShortcutAction(title: "Next Subtitle Track", group: "Subtitles", command: .cycleTrack(.subtitle)),
        ShortcutAction(title: "Subtitles Later", group: "Subtitles", command: .shiftSubtitleDelay(0.1)),
        ShortcutAction(title: "Subtitles Earlier", group: "Subtitles", command: .shiftSubtitleDelay(-0.1)),
        ShortcutAction(title: "Full Screen", group: "Window", command: .toggleFullScreen),
        ShortcutAction(title: "Leave Full Screen", group: "Window", command: .exitFullScreen),
        ShortcutAction(title: "Picture in Picture", group: "Window", command: .togglePictureInPicture),
        ShortcutAction(title: "Mini Player", group: "Window", command: .toggleMiniPlayer),
        ShortcutAction(title: "Always on Top", group: "Window", command: .toggleAlwaysOnTop),
        ShortcutAction(title: "Video Settings", group: "Window", command: .toggleSettings(.video)),
        ShortcutAction(title: "Audio Settings", group: "Window", command: .toggleSettings(.audio)),
        ShortcutAction(title: "Subtitle Settings", group: "Window", command: .toggleSettings(.subtitles)),
        ShortcutAction(title: "Save Screenshot", group: "Other", command: .screenshot(includingSubtitles: true)),
        ShortcutAction(title: "Save Screenshot Without Subtitles", group: "Other", command: .screenshot(includingSubtitles: false)),
    ]
}

public extension ShortcutAction {
    /// The entry for a command: the listed one, or a described one for a command with another
    /// amount (a bindings file can seek by any number of seconds). `nil` if it cannot be stored.
    static func describing(_ command: PlayerCommand) -> ShortcutAction? {
        if let listed = all.first(where: { $0.command == command }) {
            return listed
        }
        guard command.identifier != nil else { return nil }
        func amount(_ value: Double) -> String {
            let size = abs(value)
            return size == size.rounded() ? String(Int(size)) : String(size)
        }
        let title: String? = switch command {
        case let .seekBy(seconds): "\(seconds < 0 ? "Back" : "Forward") \(amount(seconds)) Seconds"
        case let .changeVolumeBy(change): "Volume \(change < 0 ? "Down" : "Up") by \(amount(change))"
        case let .shiftSubtitleDelay(seconds): "Subtitles \(seconds < 0 ? "Earlier" : "Later") by \(amount(seconds)) s"
        case let .shiftAudioDelay(seconds): "Sound \(seconds < 0 ? "Earlier" : "Later") by \(amount(seconds)) s"
        case .cycleTrack(.video): "Next Video Track"
        case .closePlayer: "Close the Player"
        default: nil
        }
        return title.map { ShortcutAction(title: $0, group: "Other", command: command) }
    }
}

public extension KeyChord {
    /// The chord as menus show it: "⌃⌥⇧⌘K", "Space", "←".
    var displayText: String {
        var text = ""
        if modifiers.contains(.control) {
            text += "⌃"
        }
        if modifiers.contains(.option) {
            text += "⌥"
        }
        if modifiers.contains(.shift) {
            text += "⇧"
        }
        if modifiers.contains(.command) {
            text += "⌘"
        }
        switch key {
        case .space: text += "Space"
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .escape: text += "Esc"
        case .returnKey: text += "Return"
        case let .character(character): text += String(character).uppercased()
        }
        return text
    }

    /// The chord in words, for VoiceOver: "Command Shift S", "Left Arrow".
    var spokenText: String {
        var words: [String] = []
        if modifiers.contains(.control) {
            words.append("Control")
        }
        if modifiers.contains(.option) {
            words.append("Option")
        }
        if modifiers.contains(.shift) {
            words.append("Shift")
        }
        if modifiers.contains(.command) {
            words.append("Command")
        }
        switch key {
        case .space: words.append("Space")
        case .leftArrow: words.append("Left Arrow")
        case .rightArrow: words.append("Right Arrow")
        case .upArrow: words.append("Up Arrow")
        case .downArrow: words.append("Down Arrow")
        case .escape: words.append("Escape")
        case .returnKey: words.append("Return")
        case let .character(character): words.append(String(character).uppercased())
        }
        return words.joined(separator: " ")
    }
}
