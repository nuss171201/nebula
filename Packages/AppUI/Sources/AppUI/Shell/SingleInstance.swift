import Foundation

/// Decides whether this copy of the app should step aside for one that is already running.
///
/// Two copies with the same identity (the installed one and one opened from a disk image, say)
/// share one library and one stream cache. Each trims the cache when it starts without knowing
/// what the other is playing, so a second copy could delete the film being watched in the
/// first. The second copy therefore brings the first forward and quits.
public enum SingleInstance {
    public struct RunningApp: Sendable, Equatable {
        public var processIdentifier: Int32
        public var bundleIdentifier: String?
        public var launchDate: Date?

        public init(processIdentifier: Int32, bundleIdentifier: String?, launchDate: Date? = nil) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.launchDate = launchDate
        }
    }

    /// The copy to hand over to, if there is one.
    /// - Parameters:
    ///   - usesOwnProfile: Whether this copy keeps its data in a folder of its own (a check
    ///     with a scratch profile). Such a copy shares nothing and may run alongside.
    public static func instanceToYieldTo(
        bundleIdentifier: String,
        ownProcess: Int32,
        usesOwnProfile: Bool,
        running: [RunningApp]
    ) -> RunningApp? {
        guard !usesOwnProfile, !bundleIdentifier.isEmpty else { return nil }
        return running
            .filter { $0.bundleIdentifier == bundleIdentifier && $0.processIdentifier != ownProcess }
            // The one that has been running longest is the one with the user's session in it.
            .min { ($0.launchDate ?? .distantFuture, $0.processIdentifier) < ($1.launchDate ?? .distantFuture, $1.processIdentifier) }
    }
}
