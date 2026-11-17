import Foundation

/// Something the player is allowed to open: a local file or an http(s) URL.
///
/// Addresses can come from add-ons, so the scheme is checked here. The engine itself
/// understands many more "protocols", some of which read local files or run filters.
public struct PlayableSource: Sendable, Hashable {
    public enum Rejection: Error, Sendable, Equatable {
        case empty
        case unsupportedScheme(String)
        case notAbsolute

        public var userMessage: String {
            switch self {
            case .empty: "Enter a file path or a web address."
            case let .unsupportedScheme(scheme): "“\(scheme)” addresses cannot be played. Use a file or an http(s) address."
            case .notAbsolute: "That is not a complete file path or web address."
            }
        }
    }

    public let url: URL

    public init(url: URL) throws(Rejection) {
        switch url.scheme?.lowercased() {
        case "file":
            guard url.path.hasPrefix("/") else { throw .notAbsolute }
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { throw .notAbsolute }
        case let scheme?:
            throw .unsupportedScheme(scheme)
        case nil:
            throw .notAbsolute
        }
        self.url = url
    }

    /// Accepts what a user types or pastes: an absolute path, a `~` path, or a URL.
    public init(userInput: String) throws(Rejection) {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            try self.init(url: URL(fileURLWithPath: (text as NSString).expandingTildeInPath))
        } else if let url = URL(string: text), url.scheme != nil {
            try self.init(url: url)
        } else if let separator = text.range(of: "://") {
            // Not parseable as a URL, but it names a scheme: say that the scheme is the problem.
            throw .unsupportedScheme(text[..<separator.lowerBound].lowercased())
        } else {
            throw .notAbsolute
        }
    }

    public var isLocalFile: Bool {
        url.isFileURL
    }

    /// The form handed to the engine: a plain absolute path for files, the URL otherwise.
    var engineArgument: String {
        url.isFileURL ? url.path : url.absoluteString
    }

    /// A name to show until the media reports its own title.
    public var displayName: String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? url.absoluteString) : last
    }
}

/// How the playback engine is set up. Everything here is fixed for the life of one player.
public struct PlayerConfiguration: Sendable, Equatable {
    public enum VideoOutput: Sendable, Equatable {
        /// Render into the player's Metal surface.
        case surface
        /// Decode without showing video. For tests.
        case none
    }

    /// Sent with every network request the engine makes.
    public var userAgent: String
    /// Subsystem for the engine's log messages.
    public var logSubsystem: String
    public var videoOutput: VideoOutput
    /// Decode with VideoToolbox when the format allows; falls back to software otherwise.
    public var usesHardwareDecoding: Bool
    /// `false` discards audio instead of playing it. For tests and silent checks.
    public var playsAudio: Bool

    public init(
        userAgent: String,
        logSubsystem: String,
        videoOutput: VideoOutput = .surface,
        usesHardwareDecoding: Bool = true,
        playsAudio: Bool = true
    ) {
        self.userAgent = userAgent
        self.logSubsystem = logSubsystem
        self.videoOutput = videoOutput
        self.usesHardwareDecoding = usesHardwareDecoding
        self.playsAudio = playsAudio
    }

    /// The engine options this configuration translates to, in the order they are applied.
    ///
    /// The app is the only thing in control: the engine's own window, key bindings,
    /// on-screen controller, scripts and config files are all switched off.
    var engineOptions: [(name: String, value: String)] {
        var options: [(String, String)] = [
            ("config", "no"),
            ("terminal", "no"),
            ("idle", "yes"),
            ("keep-open", "yes"),
            ("osc", "no"),
            ("ytdl", "no"),
            ("load-scripts", "no"),
            ("load-stats-overlay", "no"),
            ("load-osd-console", "no"),
            ("load-auto-profiles", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("input-media-keys", "no"),
            ("cursor-autohide", "no"),
            ("resume-playback", "no"),
            ("save-position-on-quit", "no"),
            ("volume-max", "100"),
            ("user-agent", userAgent),
            ("network-timeout", "30"),
            ("hwdec", usesHardwareDecoding ? "videotoolbox" : "no"),
        ]
        switch videoOutput {
        case .surface:
            options += [("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk")]
        case .none:
            options += [("vo", "null")]
        }
        if !playsAudio {
            options.append(("ao", "null"))
        }
        return options
    }
}
