import Foundation

/// The volume the user last left the player at.
public struct RememberedVolume: Sendable, Equatable, Codable {
    /// 0–100.
    public var level: Double
    public var isMuted: Bool

    public init(level: Double, isMuted: Bool) {
        self.level = level
        self.isMuted = isMuted
    }
}

/// Where the player keeps what it should remember between sessions. Implemented by the
/// app on top of its database; the player itself knows nothing about storage.
public protocol PlayerMemory: Sendable {
    /// The choice stored under the first of `keys` that has one. Keys go from most specific
    /// (this file) to least (its folder or series).
    func rememberedTracks(forAnyOf keys: [String]) async -> RememberedTracks?
    /// Stores the choice under every key, so a later episode finds it under the shared one.
    func remember(_ tracks: RememberedTracks, for keys: [String]) async
    func rememberedVolume() async -> RememberedVolume?
    func remember(_ volume: RememberedVolume) async
    /// Where the user stopped watching the thing stored under `key`, in seconds.
    func rememberedPosition(for key: String) async -> Double?
    /// Stores where the user stopped; `nil` forgets it (the file was watched to the end).
    func remember(position: Double?, for key: String) async
}

public extension PlayerMemory {
    func rememberedPosition(for _: String) async -> Double? {
        nil
    }

    func remember(position _: Double?, for _: String) async {}
}

public extension PlayableSource {
    /// Keys under which choices for this source are remembered: the file itself, then its
    /// folder (episodes of a series usually share one). Streams are keyed by address without
    /// the query, which often carries a token that changes every time.
    var memoryKeys: [String] {
        if url.isFileURL {
            return ["file:" + url.path, "folder:" + url.deletingLastPathComponent().path]
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return ["url:" + (components?.string ?? url.absoluteString)]
    }
}
