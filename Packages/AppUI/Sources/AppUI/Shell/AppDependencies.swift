import Foundation
import MediaCore
import MediaLibrary
import PlayerKit
import StreamEngine

/// The long-lived services the UI is built from. Created once by the app target.
public struct AppDependencies: Sendable {
    public let branding: AppBranding
    public let addonClient: AddonClient
    public let addonStore: AddonStore
    public let settings: SettingsStore
    public let playbackMemory: PlaybackMemoryStore
    public let libraryStore: LibraryStore
    public let watchHistory: WatchHistoryStore
    /// The list of downloads.
    public let downloadStore: DownloadStore
    /// Where downloaded files are kept.
    public let downloadsDirectory: URL
    public let imagePipeline: ImagePipeline
    /// The add-ons installed without being asked for, each with the round it came in.
    public let defaultAddons: [DefaultAddon]
    public let playerConfiguration: PlayerConfiguration
    /// Whether the player appears in the system's Now Playing display and answers media keys.
    /// Off for silent checks and tests, which must not take the user's media keys from their music.
    public let usesSystemNowPlaying: Bool
    /// Plays torrents: the engine, the loopback server and the cache, started on first use.
    public let streamManager: StreamManager
    /// Finds and downloads subtitles through installed add-ons.
    public let subtitleService: AddonSubtitleService
    /// Where the user can keep an `mpv.conf` and an `input.conf`; `nil` reads none.
    public let engineConfigFolder: EngineConfigFolder?
    /// Set when something went wrong during startup that the user should know about.
    public let startupWarning: String?

    public init(
        branding: AppBranding,
        addonClient: AddonClient,
        database: LibraryDatabase,
        imagePipeline: ImagePipeline,
        defaultAddonAddresses: [String],
        defaultAddons: [DefaultAddon]? = nil,
        playerConfiguration: PlayerConfiguration? = nil,
        usesSystemNowPlaying: Bool = false,
        streamManager: StreamManager? = nil,
        subtitleHTTP: (any HTTPClient)? = nil,
        subtitleDirectory: URL? = nil,
        engineConfigFolder: EngineConfigFolder? = nil,
        downloadsDirectory: URL? = nil,
        startupWarning: String? = nil
    ) {
        self.branding = branding
        self.addonClient = addonClient
        addonStore = AddonStore(database: database)
        settings = SettingsStore(database: database)
        playbackMemory = PlaybackMemoryStore(database: database)
        libraryStore = LibraryStore(database: database)
        watchHistory = WatchHistoryStore(database: database)
        downloadStore = DownloadStore(database: database)
        // Without a place of its own, downloads go to a folder that is cleared with the temporary files.
        self.downloadsDirectory = downloadsDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("downloads-\(UUID().uuidString)", isDirectory: true)
        self.imagePipeline = imagePipeline
        self.defaultAddons = defaultAddons ?? defaultAddonAddresses.map { DefaultAddon(address: $0) }
        self.playerConfiguration = playerConfiguration ?? PlayerConfiguration(
            userAgent: branding.userAgent,
            logSubsystem: branding.bundleIdentifier
        )
        self.usesSystemNowPlaying = usesSystemNowPlaying
        // Without a place of its own (tests, previews) streams stay on this machine and in a
        // folder that is cleared with the temporary files.
        self.streamManager = streamManager ?? StreamManager(
            settings: .loopback(userAgent: branding.userAgent),
            cache: StreamCache(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("streams-\(UUID().uuidString)", isDirectory: true)),
            logSubsystem: branding.bundleIdentifier
        )
        subtitleService = AddonSubtitleService(
            client: addonClient,
            http: subtitleHTTP ?? URLSessionHTTPClient(userAgent: branding.userAgent),
            // Without a place of its own, downloads go to a folder that is cleared with the temporary files.
            directory: subtitleDirectory ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("subtitles-\(UUID().uuidString)", isDirectory: true)
        )
        self.engineConfigFolder = engineConfigFolder
        self.startupWarning = startupWarning
    }

    /// The real thing: database in Application Support, caches in Caches, both in a
    /// folder named after the bundle identifier.
    ///
    /// - Parameters:
    ///   - playsAudio: `false` discards the player's audio (used when checking the app silently).
    ///   - additionalEngineOptions: Extra playback-engine options (used for experiments).
    ///   - profileDirectory: Keeps the database and caches in this folder instead of the user's
    ///     own, so that a check can install add-ons and stream without touching their data.
    ///   - streamsStayLocal: Keeps the stream engine to this machine (no trackers' peers, no
    ///     hash table, no router). For checks.
    public static func live(
        branding: AppBranding,
        defaultAddons: [DefaultAddon],
        playsAudio: Bool = true,
        additionalEngineOptions: [PlayerConfiguration.EngineOption] = [],
        profileDirectory: URL? = nil,
        streamsStayLocal: Bool = false
    ) -> AppDependencies {
        let files = FileManager.default
        let support = profileDirectory?.appendingPathComponent("Support", isDirectory: true)
            ?? files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(branding.bundleIdentifier, isDirectory: true)
        let caches = profileDirectory?.appendingPathComponent("Caches", isDirectory: true)
            ?? files.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(branding.bundleIdentifier, isDirectory: true)

        var warning: String?
        let database: LibraryDatabase
        do {
            guard let support else { throw CocoaError(.fileNoSuchFile) }
            database = try LibraryDatabase(fileURL: support.appendingPathComponent("library.sqlite"))
        } catch {
            // Keep the app usable; nothing will be remembered after quitting.
            warning = "Your library could not be opened, so changes made now will not be saved."
            database = Self.inMemoryDatabase()
        }

        // Add-on responses carry Cache-Control headers; let URLSession honour them.
        let responseCache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            directory: caches?.appendingPathComponent("HTTP", isDirectory: true)
        )
        let apiClient = URLSessionHTTPClient(userAgent: branding.userAgent, cache: responseCache)
        // Images have their own disk cache, so URLSession's is switched off for them.
        let imageClient = URLSessionHTTPClient(
            userAgent: branding.userAgent,
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(300), maxDelay: .seconds(2))
        )

        return AppDependencies(
            branding: branding,
            addonClient: AddonClient(http: apiClient),
            database: database,
            imagePipeline: ImagePipeline(
                http: imageClient,
                directory: caches?.appendingPathComponent("Images", isDirectory: true)
            ),
            defaultAddonAddresses: [],
            defaultAddons: defaultAddons,
            playerConfiguration: PlayerConfiguration(
                userAgent: branding.userAgent,
                logSubsystem: branding.bundleIdentifier,
                playsAudio: playsAudio,
                // Pictures/<app name>, so the folder says where its contents came from.
                screenshotDirectory: PlayerConfiguration.defaultScreenshotDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent(branding.name, isDirectory: true),
                // A silent run is a check, and a check starts every file from the beginning, unless
                // it has a profile of its own, where what it leaves behind is its own business.
                resumesPlayback: playsAudio || profileDirectory != nil,
                additionalEngineOptions: additionalEngineOptions
            ),
            usesSystemNowPlaying: playsAudio,
            streamManager: StreamManager(
                settings: streamsStayLocal ? .loopback(userAgent: branding.userAgent) : TorrentEngineSettings(userAgent: branding.userAgent),
                cache: StreamCache(directory: (caches ?? files.temporaryDirectory).appendingPathComponent("Streams", isDirectory: true)),
                logSubsystem: branding.bundleIdentifier
            ),
            subtitleHTTP: apiClient,
            subtitleDirectory: (caches ?? files.temporaryDirectory).appendingPathComponent("Subtitles", isDirectory: true),
            engineConfigFolder: support.map(EngineConfigFolder.init(directory:)),
            // Movies/<app name>: where a person would look for films, and a folder macOS lets an
            // app write to without asking. A check's profile keeps its downloads to itself.
            downloadsDirectory: profileDirectory?.appendingPathComponent("Downloads", isDirectory: true)
                ?? files.urls(for: .moviesDirectory, in: .userDomainMask).first?
                .appendingPathComponent(branding.name, isDirectory: true),
            startupWarning: warning
        )
    }

    /// Nothing touches the disk; network calls go through `http`. For previews and tests.
    public static func ephemeral(
        branding: AppBranding = AppBranding(name: "Preview", bundleIdentifier: "preview.app", version: "0", build: "0"),
        http: any HTTPClient,
        defaultAddonAddresses: [String] = []
    ) -> AppDependencies {
        AppDependencies(
            branding: branding,
            addonClient: AddonClient(http: http),
            database: inMemoryDatabase(),
            imagePipeline: ImagePipeline(http: http, directory: nil),
            defaultAddonAddresses: defaultAddonAddresses,
            playerConfiguration: PlayerConfiguration(
                userAgent: branding.userAgent,
                logSubsystem: branding.bundleIdentifier,
                playsAudio: false
            ),
            subtitleHTTP: http
        )
    }

    private static func inMemoryDatabase() -> LibraryDatabase {
        do {
            return try LibraryDatabase.inMemory()
        } catch {
            // An in-memory SQLite database cannot fail to open unless the process is already broken.
            preconditionFailure("Could not create an in-memory database: \(error)")
        }
    }
}
