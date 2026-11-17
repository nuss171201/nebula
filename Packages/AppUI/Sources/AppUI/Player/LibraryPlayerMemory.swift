import Foundation
import MediaLibrary
import PlayerKit

/// The player's memory, kept in the app's database.
struct LibraryPlayerMemory: PlayerMemory {
    static let volumeKey = SettingKey<RememberedVolume?>("player.volume", default: nil)
    /// The user's language preferences; `nil` means "follow the system languages".
    static let trackPreferencesKey = SettingKey<TrackPreferences?>("player.trackPreferences", default: nil)

    /// The user's changes to the player's key bindings: chord text to command identifier
    /// (see `KeyBindings.applying(overrides:)`). Empty means the standard bindings.
    static let keyBindingOverridesKey = SettingKey<[String: String]>("player.keyBindings", default: [:])

    let store: PlaybackMemoryStore
    let settings: SettingsStore

    // Failing to read or write memory must never get in the way of playback, so errors
    // degrade to "nothing remembered".

    func rememberedTracks(forAnyOf keys: [String]) async -> RememberedTracks? {
        try? await store.value(forAnyOf: keys.map(Self.trackKey), as: RememberedTracks.self)
    }

    func remember(_ tracks: RememberedTracks, for keys: [String]) async {
        try? await store.set(tracks, for: keys.map(Self.trackKey))
    }

    func rememberedVolume() async -> RememberedVolume? {
        await (try? settings.value(for: Self.volumeKey)) ?? nil
    }

    func remember(_ volume: RememberedVolume) async {
        try? await settings.set(volume, for: Self.volumeKey)
    }

    func rememberedPosition(for key: String) async -> Double? {
        try? await store.value(forAnyOf: [Self.positionKey(key)], as: Double.self)
    }

    func remember(position: Double?, for key: String) async {
        if let position {
            try? await store.set(position, for: [Self.positionKey(key)])
        } else {
            try? await store.remove(keys: [Self.positionKey(key)])
        }
    }

    private static func trackKey(_ key: String) -> String {
        "tracks|" + key
    }

    private static func positionKey(_ key: String) -> String {
        "position|" + key
    }
}
