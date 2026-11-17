import Foundation
import MediaCore
import MediaLibrary
import PlayerKit

/// The long-lived services the UI is built from. Created once by the app target.
public struct AppDependencies: Sendable {
    public let branding: AppBranding
    public let addonClient: AddonClient
    public let addonStore: AddonStore
    public let settings: SettingsStore
    public let playbackMemory: PlaybackMemoryStore
    public let imagePipeline: ImagePipeline
    /// Manifest addresses installed on first launch.
    public let defaultAddonAddresses: [String]
    public let playerConfiguration: PlayerConfiguration
    /// Set when something went wrong during startup that the user should know about.
    public let startupWarning: String?

    public init(
        branding: AppBranding,
        addonClient: AddonClient,
        database: LibraryDatabase,
        imagePipeline: ImagePipeline,
        defaultAddonAddresses: [String],
        playerConfiguration: PlayerConfiguration? = nil,
        startupWarning: String? = nil
    ) {
        self.branding = branding
        self.addonClient = addonClient
        addonStore = AddonStore(database: database)
        settings = SettingsStore(database: database)
        playbackMemory = PlaybackMemoryStore(database: database)
        self.imagePipeline = imagePipeline
        self.defaultAddonAddresses = defaultAddonAddresses
        self.playerConfiguration = playerConfiguration ?? PlayerConfiguration(
            userAgent: branding.userAgent,
            logSubsystem: branding.bundleIdentifier
        )
        self.startupWarning = startupWarning
    }

    /// The real thing: database in Application Support, caches in Caches, both in a
    /// folder named after the bundle identifier.
    ///
    /// - Parameters:
    ///   - playsAudio: `false` discards the player's audio (used when checking the app silently).
    ///   - additionalEngineOptions: Extra playback-engine options (used for experiments).
    public static func live(
        branding: AppBranding,
        defaultAddonAddresses: [String],
        playsAudio: Bool = true,
        additionalEngineOptions: [PlayerConfiguration.EngineOption] = []
    ) -> AppDependencies {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(branding.bundleIdentifier, isDirectory: true)
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first?
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
            defaultAddonAddresses: defaultAddonAddresses,
            playerConfiguration: PlayerConfiguration(
                userAgent: branding.userAgent,
                logSubsystem: branding.bundleIdentifier,
                playsAudio: playsAudio,
                // Pictures/<app name>, so the folder says where its contents came from.
                screenshotDirectory: PlayerConfiguration.defaultScreenshotDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent(branding.name, isDirectory: true),
                additionalEngineOptions: additionalEngineOptions
            ),
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
            )
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
