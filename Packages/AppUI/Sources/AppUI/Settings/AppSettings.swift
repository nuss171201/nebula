import Foundation
import MediaLibrary
import PlayerKit
import StreamEngine

/// Everything the Settings window holds. Stored as one JSON value; every field is optional
/// on reading, so settings written by another version are read as far as they go.
public struct AppSettings: Sendable, Equatable, Codable {
    public enum Appearance: String, Sendable, Codable, CaseIterable, Identifiable {
        case system, light, dark

        public var id: Self { self }

        public var title: String {
            switch self {
            case .system: "Match the System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    // MARK: Interface

    public var appearance = Appearance.system
    /// The section the app opens on.
    public var startSection = AppSection.home
    public var showsContinueWatching = true

    // MARK: Playback

    /// Languages for sound, most wanted first, as two-letter codes; `nil` follows the system's languages.
    public var audioLanguages: [String]?
    /// Languages for subtitles; `nil` follows the system's languages.
    public var subtitleLanguages: [String]?
    public var subtitleMode = TrackPreferences.SubtitleMode.automatic
    /// Whether a video opens where it was left.
    public var resumesPlayback = true
    public var autoplaysNextEpisode = true
    /// Seconds between an episode ending and the next starting.
    public var nextEpisodeCountdown = 10
    public var renderQuality = PlayerConfiguration.RenderQuality.efficient
    /// Whether `mpv.conf` and `input.conf` in the app's folder are read.
    public var readsEngineConfigFiles = true

    // MARK: Streams

    /// The picture height to prefer when nothing was played before (2160, 1080, …); `nil` prefers the best there is.
    public var preferredQualityHeight: Int?
    public var streamSort = StreamSort.quality
    /// Gigabytes of disk the stream cache may keep.
    public var cacheLimitGigabytes = 10.0
    public var connectionsLimit = 200
    /// Kilobytes per second; 0 means no limit.
    public var downloadLimit = 0
    public var uploadLimit = 0
    public var usesDHT = true
    public var usesLocalDiscovery = true
    public var mapsPorts = true

    // MARK: Watch party

    /// The name others in a party see; empty uses the person's first name as the Mac knows it.
    public var partyName = ""
    /// The signalling server new parties are started at; empty uses the one the app came with.
    public var partyServer = ""

    public static let cacheLimitRange = 1.0 ... 500.0
    public static let connectionsRange = 20 ... 1000
    public static let countdownRange = 3 ... 60

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            (try? container.decodeIfPresent(Value.self, forKey: key)) ?? fallback
        }
        let defaults = AppSettings()
        appearance = read(.appearance, defaults.appearance)
        startSection = read(.startSection, defaults.startSection)
        showsContinueWatching = read(.showsContinueWatching, defaults.showsContinueWatching)
        audioLanguages = try? container.decodeIfPresent([String].self, forKey: .audioLanguages)
        subtitleLanguages = try? container.decodeIfPresent([String].self, forKey: .subtitleLanguages)
        subtitleMode = read(.subtitleMode, defaults.subtitleMode)
        resumesPlayback = read(.resumesPlayback, defaults.resumesPlayback)
        autoplaysNextEpisode = read(.autoplaysNextEpisode, defaults.autoplaysNextEpisode)
        nextEpisodeCountdown = read(.nextEpisodeCountdown, defaults.nextEpisodeCountdown)
        renderQuality = read(.renderQuality, defaults.renderQuality)
        readsEngineConfigFiles = read(.readsEngineConfigFiles, defaults.readsEngineConfigFiles)
        preferredQualityHeight = try? container.decodeIfPresent(Int.self, forKey: .preferredQualityHeight)
        streamSort = read(.streamSort, defaults.streamSort)
        cacheLimitGigabytes = read(.cacheLimitGigabytes, defaults.cacheLimitGigabytes)
        connectionsLimit = read(.connectionsLimit, defaults.connectionsLimit)
        downloadLimit = read(.downloadLimit, defaults.downloadLimit)
        uploadLimit = read(.uploadLimit, defaults.uploadLimit)
        usesDHT = read(.usesDHT, defaults.usesDHT)
        usesLocalDiscovery = read(.usesLocalDiscovery, defaults.usesLocalDiscovery)
        mapsPorts = read(.mapsPorts, defaults.mapsPorts)
        partyName = read(.partyName, defaults.partyName)
        partyServer = read(.partyServer, defaults.partyServer)
        self = clamped
    }

    /// The same settings with every number inside what the app accepts.
    public var clamped: AppSettings {
        var settings = self
        settings.cacheLimitGigabytes = min(max(cacheLimitGigabytes, Self.cacheLimitRange.lowerBound), Self.cacheLimitRange.upperBound)
        settings.connectionsLimit = min(max(connectionsLimit, Self.connectionsRange.lowerBound), Self.connectionsRange.upperBound)
        settings.nextEpisodeCountdown = min(max(nextEpisodeCountdown, Self.countdownRange.lowerBound), Self.countdownRange.upperBound)
        settings.downloadLimit = max(downloadLimit, 0)
        settings.uploadLimit = max(uploadLimit, 0)
        return settings
    }

    // MARK: - What the settings come to for each part of the app

    /// Which tracks to pick when a file opens.
    public func trackPreferences(systemLanguages: [String] = Locale.preferredLanguages) -> TrackPreferences {
        let system = TrackPreferences.system(preferredLanguages: systemLanguages)
        return TrackPreferences(
            audioLanguages: audioLanguages ?? system.audioLanguages,
            subtitleLanguages: subtitleLanguages ?? system.subtitleLanguages,
            subtitleMode: subtitleMode
        )
    }

    public var cachePolicy: StreamCachePolicy {
        StreamCachePolicy(maximumBytes: Int64(clamped.cacheLimitGigabytes * 1_073_741_824))
    }

    /// The stream engine's settings, starting from the ones it was started with (which carry what is not a setting).
    public func engineSettings(basedOn base: TorrentEngineSettings) -> TorrentEngineSettings {
        var settings = base
        let limits = clamped
        settings.connectionsLimit = limits.connectionsLimit
        settings.downloadRateLimit = limits.downloadLimit * 1024
        settings.uploadRateLimit = limits.uploadLimit * 1024
        // Only ever narrower than the engine was started with: an engine that was told to stay
        // on this machine (checks, tests) must not be opened to the network by a stored setting.
        settings.usesDHT = base.usesDHT && usesDHT
        settings.usesLocalDiscovery = base.usesLocalDiscovery && usesLocalDiscovery
        settings.mapsPorts = base.mapsPorts && mapsPorts
        return settings
    }

    public var preferredQuality: StreamQuality? {
        preferredQualityHeight.flatMap(StreamQuality.init(rawValue:))
    }
}

extension AppSection: Codable {}
extension StreamQuality: Codable {}

public extension PlayerConfiguration.RenderQuality {
    var title: String {
        switch self {
        case .efficient: "Efficient"
        case .high: "High Quality"
        }
    }
}

enum SettingsKeys {
    static let app = SettingKey<AppSettings>("app.settings", default: AppSettings())
    static let playerDefaults = SettingKey<PlayerDefaults>("player.defaults", default: PlayerDefaults())
}

public extension TrackPreferences.SubtitleMode {
    var title: String {
        switch self {
        case .automatic: "When the Sound Is in Another Language"
        case .always: "Always"
        case .off: "Never"
        }
    }
}
