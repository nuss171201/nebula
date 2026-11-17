import Foundation
import MediaLibrary
import PlayerKit

/// The player's memory, kept in the app's database.
struct LibraryPlayerMemory: PlayerMemory {
    static let volumeKey = SettingKey<RememberedVolume?>("player.volume", default: nil)
    /// The user's language preferences; `nil` means "follow the system languages".
    static let trackPreferencesKey = SettingKey<TrackPreferences?>("player.trackPreferences", default: nil)

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

    private static func trackKey(_ key: String) -> String {
        "tracks|" + key
    }
}
