import Foundation
import MediaLibrary
import Observation
import PlayerKit
import StreamEngine

/// The app's settings: loads them, keeps them, and hands every change to the parts of the
/// app it concerns (the player, the stream engine, autoplay, the stream lists).
@MainActor
@Observable
public final class SettingsModel {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// What the Settings window edits. Assigning applies and saves.
    public var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            apply()
            saveSoon()
        }
    }

    /// Bytes the stream cache holds on disk, as last measured.
    public private(set) var cacheBytes: Int64 = 0
    public private(set) var hasLoaded = false
    /// How fast the connection has been seen to download, in bytes a second; `nil` before any stream was played.
    public private(set) var measuredSpeed: Double?
    /// What the engine's config files contained when they were last read.
    public private(set) var configReport = EngineConfigReport()
    /// The tab the Settings window shows.
    public var selectedTab = SettingsTab.general
    /// The player's keyboard shortcuts.
    public let shortcuts: ShortcutsModel
    /// Where the engine's config files are looked for; `nil` reads none (tests).
    public let configFolder: EngineConfigFolder?

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let coordinator: PlayerCoordinator
    @ObservationIgnored private let streamManager: StreamManager
    @ObservationIgnored private let nextEpisode: NextEpisodeController
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var defaultsTask: Task<Void, Never>?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var speedTask: Task<Void, Never>?
    /// The player's configuration as the app was started with, which carries what is not a setting.
    @ObservationIgnored private let baseConfiguration: PlayerConfiguration
    @ObservationIgnored private var baseEngineSettings: TorrentEngineSettings?
    @ObservationIgnored private var playerDefaults = PlayerDefaults()

    public init(
        store: SettingsStore,
        coordinator: PlayerCoordinator,
        streamManager: StreamManager,
        nextEpisode: NextEpisodeController,
        configFolder: EngineConfigFolder? = nil,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.configFolder = configFolder
        shortcuts = ShortcutsModel(store: store, coordinator: coordinator)
        self.coordinator = coordinator
        self.streamManager = streamManager
        self.nextEpisode = nextEpisode
        self.sleep = sleep
        baseConfiguration = coordinator.configuration
        coordinator.onPlayerDefaultsChanged = { [weak self] defaults in
            self?.playerDefaultsChanged(defaults)
        }
    }

    /// Reads the stored settings and applies them. Call once, at launch.
    public func load() async {
        let stored = await (try? store.value(for: SettingsKeys.app)) ?? AppSettings()
        playerDefaults = await (try? store.value(for: SettingsKeys.playerDefaults)) ?? PlayerDefaults()
        measuredSpeed = await (try? store.value(for: SettingsKeys.measuredSpeed)) ?? nil
        baseEngineSettings = await streamManager.settings
        await shortcuts.load()
        configReport = await Self.read(configFolder)
        hasLoaded = true
        if stored != settings {
            // Applies through the observer; saving what was just read is harmless.
            settings = stored
        } else {
            apply()
        }
    }

    public func resetToDefaults() {
        settings = AppSettings()
    }

    /// What Play goes by when it chooses a stream, as things stand now.
    public var pickerContext: StreamPicker.Context {
        settings.pickerContext(measuredSpeed: measuredSpeed)
    }

    /// A stream has finished: what it achieved says something about the connection.
    /// - Parameter bestRate: The best download rate it held for a few seconds, in bytes a second.
    public func noteStreamSession(bestRate: Double) {
        guard let updated = ConnectionSpeed.updated(measuredSpeed, sessionBest: bestRate), updated != measuredSpeed else { return }
        measuredSpeed = updated
        speedTask = Task { [store, previous = speedTask] in
            await previous?.value
            try? await store.set(updated, for: SettingsKeys.measuredSpeed)
        }
    }

    /// Forgets what was learned about the connection (it has changed, say).
    public func forgetMeasuredSpeed() {
        measuredSpeed = nil
        speedTask = Task { [store, previous = speedTask] in
            await previous?.value
            try? await store.reset(SettingsKeys.measuredSpeed)
        }
    }

    /// Reads the engine's config files again. They apply to videos opened from then on.
    public func reloadConfigFiles() async {
        configReport = await Self.read(configFolder)
        apply()
    }

    private static func read(_ folder: EngineConfigFolder?) async -> EngineConfigReport {
        guard let folder else { return EngineConfigReport() }
        return await Task.detached(priority: .userInitiated) { folder.load() }.value
    }

    /// Measures the stream cache again.
    public func refreshCacheSize() async {
        cacheBytes = await streamManager.cacheSize()
    }

    /// Deletes everything in the stream cache that is not playing.
    public func clearCache() async {
        await streamManager.clearCache()
        await refreshCacheSize()
    }

    /// Waits for pending writes. For tests.
    func waitForSave() async {
        await saveTask?.value
        await defaultsTask?.value
        await engineTask?.value
        await speedTask?.value
        await shortcuts.waitForSave()
    }

    // MARK: - Applying

    private func apply() {
        guard hasLoaded else { return }
        var configuration = baseConfiguration
        configuration.trackPreferences = settings.trackPreferences()
        // A silent check never resumes, whatever the setting.
        configuration.resumesPlayback = baseConfiguration.resumesPlayback && settings.resumesPlayback
        configuration.renderQuality = settings.renderQuality
        configuration.defaults = playerDefaults
        // The file's options first: what the app was started with (experiments) has the last word.
        let usesFiles = settings.readsEngineConfigFiles
        configuration.additionalEngineOptions = (usesFiles ? configReport.options : []) + baseConfiguration.additionalEngineOptions
        coordinator.configuration = configuration
        shortcuts.setFileBindings(usesFiles ? configReport.bindings : [:])

        nextEpisode.isEnabled = settings.autoplaysNextEpisode
        nextEpisode.countdown = settings.clamped.nextEpisodeCountdown

        let policy = settings.cachePolicy
        let engineSettings = baseEngineSettings.map(settings.engineSettings(basedOn:))
        // One after another, so that the last change is the one the engine ends up with.
        engineTask = Task { [streamManager, previous = engineTask] in
            await previous?.value
            if let engineSettings {
                await streamManager.updateSettings(engineSettings)
            }
            await streamManager.setCachePolicy(policy)
        }
    }

    /// Writes a moment after the last change, so dragging a slider saves once.
    private func saveSoon() {
        saveTask?.cancel()
        let settings = settings
        saveTask = Task { [store, sleep] in
            do {
                try await sleep(.milliseconds(400))
            } catch {
                return
            }
            try? await store.set(settings, for: SettingsKeys.app)
        }
    }

    /// The user changed something in the player's panel that carries over to the next video.
    private func playerDefaultsChanged(_ defaults: PlayerDefaults) {
        guard defaults != playerDefaults else { return }
        playerDefaults = defaults
        coordinator.configuration.defaults = defaults
        defaultsTask?.cancel()
        defaultsTask = Task { [store, sleep] in
            do {
                try await sleep(.milliseconds(600))
            } catch {
                return
            }
            try? await store.set(defaults, for: SettingsKeys.playerDefaults)
        }
    }
}

/// The tabs of the Settings window.
public enum SettingsTab: String, Sendable, CaseIterable, Identifiable {
    case general, playback, streaming, shortcuts, advanced

    public var id: Self { self }

    public var title: String {
        switch self {
        case .general: "General"
        case .playback: "Playback"
        case .streaming: "Streaming"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .playback: "play.rectangle"
        case .streaming: "arrow.down.circle"
        case .shortcuts: "keyboard"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}
