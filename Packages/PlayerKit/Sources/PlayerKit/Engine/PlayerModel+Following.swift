import Foundation

/// Something the person at the player did to playback themselves, as opposed to what the engine
/// did by itself or what was done to keep this player with others.
public enum PlaybackIntent: Sendable, Equatable {
    case setPaused(Bool)
    /// A jump of theirs has landed at this position, in seconds.
    case seeked(to: Double)
    case speed(Double)
}

/// Being steered from outside. A watch party keeps this player where the others are by pausing,
/// seeking and nudging its speed; it must be able to tell those changes from the ones the person
/// at this Mac makes, which it passes on to everyone else.
public extension PlayerModel {
    /// Runs changes that come from outside, so that they are not reported as the person's own.
    func followingExternal(_ changes: () -> Void) {
        let wasFollowing = isFollowingExternal
        isFollowingExternal = true
        defer { isFollowingExternal = wasFollowing }
        changes()
    }

    internal func report(_ intent: PlaybackIntent) {
        guard !isFollowingExternal else { return }
        onPlaybackIntent?(intent)
    }

    /// A jump has been asked for. Where it lands is only known once the picture is back, so a
    /// jump of the person's own is reported then. One from outside takes the place of theirs.
    internal func noteSeek() {
        userSeekRequestedAt = isFollowingExternal ? nil : .now
    }

    /// Whether a jump of the person's own is still on its way. While it is, where the player is
    /// says nothing about where it should be. A jump that is never heard of again stops counting.
    var hasPendingUserSeek: Bool {
        userSeekRequestedAt.map { ContinuousClock.now - $0 < .seconds(10) } ?? false
    }

    internal func reportLandedSeek() {
        guard userSeekRequestedAt != nil else { return }
        userSeekRequestedAt = nil
        // Read from the engine: the playhead the views follow can be a moment behind.
        let landed = client.string("time-pos").flatMap(Double.init) ?? state.position
        onPlaybackIntent?(.seeked(to: max(landed, 0)))
    }

    /// The engine plays at the chosen speed times the adjustment. The adjustment is not shown:
    /// it is a few per cent for a few seconds, to close a gap without a jump.
    internal func applySpeed() {
        client.set("speed", to: .double(speed.value * min(max(speedAdjustment, 0.5), 2)))
    }
}
