import Foundation
import PlayerKit

/// What was read from the playback engine's two config files, and what was left out.
public struct EngineConfigReport: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var url: URL
        public var exists = false
        /// Lines that took effect.
        public var usedCount = 0
        public var ignored: [IgnoredConfigLine] = []
        /// Set when the file is there but could not be read.
        public var problem: String?
    }

    public var options: [PlayerConfiguration.EngineOption] = []
    public var bindings: [KeyChord: PlayerCommand?] = [:]
    public var optionsFile: File?
    public var bindingsFile: File?

    public init() {}
}

/// The folder where the user can keep an `mpv.conf` and an `input.conf` for the player.
///
/// It is the app's own folder, not `~/.config/mpv`: files written for another player are
/// not picked up by surprise, and the app never reads outside its own place.
public struct EngineConfigFolder: Sendable {
    public static let optionsFileName = "mpv.conf"
    public static let bindingsFileName = "input.conf"
    /// Config files are a few lines long; anything larger is not one.
    static let maximumFileSize = 256 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var optionsFileURL: URL {
        directory.appendingPathComponent(Self.optionsFileName)
    }

    public var bindingsFileURL: URL {
        directory.appendingPathComponent(Self.bindingsFileName)
    }

    /// Reads both files. Touches the disk: call it off the main thread.
    public func load() -> EngineConfigReport {
        var report = EngineConfigReport()
        var optionsFile = EngineConfigReport.File(url: optionsFileURL)
        if let text = Self.read(optionsFileURL, into: &optionsFile) {
            let parsed = EngineConfigFile.parse(text)
            report.options = parsed.options
            optionsFile.usedCount = parsed.options.count
            optionsFile.ignored = parsed.ignored
        }
        report.optionsFile = optionsFile

        var bindingsFile = EngineConfigReport.File(url: bindingsFileURL)
        if let text = Self.read(bindingsFileURL, into: &bindingsFile) {
            let parsed = InputConfigFile.parse(text)
            report.bindings = parsed.bindings
            bindingsFile.usedCount = parsed.bindings.count
            bindingsFile.ignored = parsed.ignored
        }
        report.bindingsFile = bindingsFile
        return report
    }

    /// Makes sure the folder is there, so that it can be shown in Finder.
    public func create() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func read(_ url: URL, into file: inout EngineConfigReport.File) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else {
            return nil
        }
        file.exists = true
        guard (values.fileSize ?? 0) <= maximumFileSize else {
            file.problem = "The file is too large to be a config file."
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            file.problem = "The file could not be read."
            return nil
        }
        guard let text = String(bytes: data, encoding: .utf8) else {
            file.problem = "The file is not plain text (UTF-8)."
            return nil
        }
        return text
    }
}

public extension EngineConfigReport.File {
    /// One line on what became of the file: "Not there", "3 options in use, 1 line left out".
    /// - Parameter noun: What a line of this file is: "option" or "shortcut".
    func summary(noun: String) -> String {
        guard exists else { return "Not there" }
        if let problem {
            return problem
        }
        func count(_ number: Int, _ word: String) -> String {
            "\(number) \(word)\(number == 1 ? "" : "s")"
        }
        let used = usedCount == 0 ? "Nothing in use" : "\(count(usedCount, noun)) in use"
        return ignored.isEmpty ? used : "\(used), \(count(ignored.count, "line")) left out"
    }
}
