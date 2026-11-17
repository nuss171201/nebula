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

/// How one source is to be opened, beyond its address.
public struct PlaybackOptions: Sendable, Equatable {
    /// Names under which track choices and the position are remembered, most specific first.
    /// `nil` uses the file and its folder, or the stream's address.
    public var memoryKeys: [String]?
    /// Whether still frames are made for the seek bar. They need a second connection to the
    /// source, which a stream that is still being fetched cannot spare.
    public var generatesThumbnails: Bool
    /// Extra HTTP headers the source's server needs, as an add-on may ask for.
    public var httpHeaders: [String: String]
    /// What to call it, when the caller knows better than the file's own name does.
    public var title: String?

    public init(
        memoryKeys: [String]? = nil,
        generatesThumbnails: Bool = true,
        httpHeaders: [String: String] = [:],
        title: String? = nil
    ) {
        self.title = title
        self.memoryKeys = memoryKeys
        self.generatesThumbnails = generatesThumbnails
        self.httpHeaders = httpHeaders
    }

    /// The headers as the engine's per-file option, or `nil` when there are none to send.
    ///
    /// The engine takes a comma-separated list, so commas inside a value are escaped; the whole
    /// value is passed with its length in front, which is how the engine is told where it ends.
    /// Names and values that could break out of a header line are dropped.
    var headerOption: String? {
        let lines = httpHeaders.sorted { $0.key < $1.key }.compactMap { name, value -> String? in
            let isValidName = !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            let isValidValue = !value.contains { $0.isNewline } && !value.contains("\0")
            guard isValidName, isValidValue else { return nil }
            return "\(name): \(value)".replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
        }
        guard !lines.isEmpty else { return nil }
        let list = lines.joined(separator: ",")
        return "http-header-fields=%\(list.utf8.count)%\(list)"
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

    /// How much work the renderer does per frame.
    ///
    /// Measured on an M4 Pro playing 4K HEVC 10-bit HDR at 60 fps into a 3024×1964 canvas
    /// (medians of three runs): `efficient` about 20 % of one core and 275 MB;
    /// `high` about 35 % and 533 MB. See the performance log in CLAUDE.md.
    public enum RenderQuality: String, Sendable, Equatable, CaseIterable, Codable {
        /// Bilinear scaling, no HDR peak detection, ordered dithering. Meets the app's CPU and memory targets.
        case efficient
        /// The engine's own defaults: high-quality scalers in linear light and HDR peak detection.
        case high

        var engineOptions: [(String, String)] {
            switch self {
            case .efficient: [("profile", "fast"), ("dither", "ordered"), ("dither-depth", "auto")]
            case .high: []
            }
        }
    }

    /// Sent with every network request the engine makes.
    public var userAgent: String
    /// Subsystem for the engine's log messages.
    public var logSubsystem: String
    public var videoOutput: VideoOutput
    /// Decode with VideoToolbox when the format allows; falls back to software otherwise.
    public var usesHardwareDecoding: Bool
    public var renderQuality: RenderQuality
    /// `false` discards audio instead of playing it. For tests and silent checks.
    public var playsAudio: Bool
    /// The volume the player starts at, 0–100.
    public var initialVolume: Double
    /// Which languages to pick for sound and subtitles when a file opens.
    public var trackPreferences: TrackPreferences
    /// Where screenshots are saved. Created when the first one is taken.
    public var screenshotDirectory: URL
    /// Converts audio the engine cannot decode; `nil` when no ffmpeg program is available.
    public var audioTranscoder: AudioTranscoder?
    /// Whether a file opens where it was left last time, and where it is left is remembered.
    public var resumesPlayback: Bool
    /// What the panel's settings start at.
    public var defaults: PlayerDefaults
    /// Further engine options, applied after the built-in ones so they can override them.
    /// Used for the user's own engine configuration and for experiments.
    public var additionalEngineOptions: [EngineOption]

    /// A "Screenshots" folder in the user's Pictures folder.
    public static var defaultScreenshotDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("Screenshots", isDirectory: true)
    }

    public struct EngineOption: Sendable, Equatable {
        public var name: String
        public var value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }

        /// Parses `name=value,name=value`. Entries without a name are skipped.
        public static func parse(_ text: String) -> [EngineOption] {
            text.split(separator: ",").compactMap { entry in
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "yes"
                return EngineOption(name, value)
            }
        }
    }

    public init(
        userAgent: String,
        logSubsystem: String,
        videoOutput: VideoOutput = .surface,
        usesHardwareDecoding: Bool = true,
        renderQuality: RenderQuality = .efficient,
        playsAudio: Bool = true,
        initialVolume: Double = 100,
        trackPreferences: TrackPreferences = .system(),
        screenshotDirectory: URL = PlayerConfiguration.defaultScreenshotDirectory,
        audioTranscoder: AudioTranscoder? = .locate(),
        resumesPlayback: Bool = true,
        defaults: PlayerDefaults = PlayerDefaults(),
        additionalEngineOptions: [EngineOption] = []
    ) {
        self.userAgent = userAgent
        self.logSubsystem = logSubsystem
        self.videoOutput = videoOutput
        self.usesHardwareDecoding = usesHardwareDecoding
        self.renderQuality = renderQuality
        self.playsAudio = playsAudio
        self.initialVolume = min(max(initialVolume, 0), 100)
        self.trackPreferences = trackPreferences
        self.screenshotDirectory = screenshotDirectory
        self.audioTranscoder = audioTranscoder
        self.resumesPlayback = resumesPlayback
        self.defaults = defaults
        self.additionalEngineOptions = additionalEngineOptions
    }

    /// Each language as both its two- and three-letter code, which is how files tag them.
    static func engineLanguageList(_ languages: [String]) -> String {
        var seen = Set<String>()
        return languages
            .compactMap(LanguageMatcher.canonical)
            .flatMap { [$0, Locale.LanguageCode($0).identifier(.alpha3) ?? $0] }
            .filter { seen.insert($0).inserted }
            .joined(separator: ",")
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
            ("volume", String(initialVolume)),
            ("user-agent", userAgent),
            ("network-timeout", "30"),
            ("hwdec", usesHardwareDecoding ? "videotoolbox" : "no"),
            // Subtitle files next to a video whose names start with the video's name load by
            // themselves, also from the folders people usually keep them in. One spelling of each
            // folder: on the usual case-insensitive disk "subs" and "Subs" are the same folder, and
            // listing both loads every file in it twice.
            ("sub-auto", "fuzzy"),
            ("sub-file-paths", "Subs:Subtitles"),
        ]
        switch videoOutput {
        case .surface:
            options += renderQuality.engineOptions
            options += [
                ("vo", "gpu-next"), ("gpu-api", "vulkan"), ("gpu-context", "moltenvk"),
                // HDR output is switched on by the player only while an HDR video is on an HDR display.
                ("target-colorspace-hint", "no"),
                // The view shows only the video's rectangle of the canvas, so subtitles must stay
                // inside the picture instead of using the black bars around it.
                ("sub-use-margins", "no"), ("sub-ass-force-margins", "no"),
            ]
        case .none:
            options += [("vo", "null")]
        }
        // A first guess for the engine, so the right track usually plays from the first sample.
        // The app's own selection (TrackSelector) runs when the file has loaded and has the last word.
        if !trackPreferences.audioLanguages.isEmpty {
            options.append(("alang", Self.engineLanguageList(trackPreferences.audioLanguages)))
        }
        options += additionalEngineOptions.map { ($0.name, $0.value) }
        // Last, so that nothing above (an options file, an experiment) can make a silent player heard.
        if !playsAudio {
            options.append(("ao", "null"))
        }
        return options
    }
}
