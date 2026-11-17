import Foundation
import MediaPlayer
import Observation

/// What the system's Now Playing display (Control Centre, the lock screen, headphones) is told.
public struct NowPlayingSnapshot: Sendable, Equatable {
    public var title: String
    /// Seconds; `nil` for live streams.
    public var duration: Double?
    /// Seconds from the start.
    public var position: Double
    /// Playback speed; the system uses it to keep its own clock running between updates.
    public var speed: Double
    public var isPlaying: Bool
    public var hasNext: Bool
    public var hasPrevious: Bool

    /// Whether the system needs telling, given what it was last told and how long ago.
    ///
    /// The system advances the position by itself, so ordinary playback needs no updates; a
    /// position that is not where the system expects it means the user has seeked.
    public func needsUpdate(after previous: NowPlayingSnapshot, secondsSince elapsed: Double) -> Bool {
        var expected = previous
        if previous.isPlaying {
            expected.position += elapsed * previous.speed
        }
        var current = self
        current.position = expected.position
        return current != expected || abs(position - expected.position) > 1.5
    }
}

/// The system's Now Playing display and its remote commands (media keys, headphone buttons).
/// A protocol so that tests need not touch the real, process-wide one.
@MainActor
public protocol NowPlayingCenter: AnyObject {
    /// Shows this, or with `nil` withdraws from the display and stops receiving commands.
    func update(_ snapshot: NowPlayingSnapshot?)
    /// Called when the user presses a media key or uses the system's controls.
    var onCommand: (@MainActor (PlayerCommand) -> Void)? { get set }
}

/// Keeps a `NowPlayingCenter` in step with a player, and routes its commands back.
@MainActor
final class NowPlayingSession {
    private let model: PlayerModel
    private let center: any NowPlayingCenter
    private var lastSent: (snapshot: NowPlayingSnapshot, at: ContinuousClock.Instant)?
    private var isActive = true

    init(model: PlayerModel, center: any NowPlayingCenter, perform: @escaping @MainActor (PlayerCommand) -> Void) {
        self.model = model
        self.center = center
        center.onCommand = perform
        refresh()
    }

    /// Withdraws from the system's display. The session does nothing afterwards.
    func stop() {
        isActive = false
        center.onCommand = nil
        center.update(nil)
    }

    static func snapshot(of model: PlayerModel) -> NowPlayingSnapshot? {
        let state = model.state
        guard state.hasMedia else { return nil }
        return NowPlayingSnapshot(
            title: model.title,
            duration: state.duration,
            position: state.position,
            speed: model.speed.value,
            isPlaying: state.isAdvancing,
            hasNext: state.playlist.count > 1 && state.playlist.last?.isCurrent == false,
            hasPrevious: state.playlist.count > 1 && state.playlist.first?.isCurrent == false
        )
    }

    private func refresh() {
        guard isActive else { return }
        let snapshot = withObservationTracking {
            Self.snapshot(of: model)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        guard let snapshot else {
            // Between files the display keeps what it had; it is cleared when the player closes.
            return
        }
        let now = ContinuousClock.now
        if let lastSent, !snapshot.needsUpdate(after: lastSent.snapshot, secondsSince: (now - lastSent.at) / .seconds(1)) {
            return
        }
        lastSent = (snapshot, now)
        center.update(snapshot)
    }
}

/// The real thing: `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`.
@MainActor
public final class SystemNowPlayingCenter: NowPlayingCenter {
    public var onCommand: (@MainActor (PlayerCommand) -> Void)?
    private var registrations: [(command: MPRemoteCommand, target: Any)] = []

    public init() {}

    public func update(_ snapshot: NowPlayingSnapshot?) {
        let info = MPNowPlayingInfoCenter.default()
        guard let snapshot else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            unregister()
            return
        }
        if registrations.isEmpty {
            register()
        }
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: snapshot.duration == nil,
        ]
        if let duration = snapshot.duration {
            values[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info.nowPlayingInfo = values
        // On the Mac the state must be said outright; it is not inferred from the rate.
        info.playbackState = snapshot.isPlaying ? .playing : .paused

        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = snapshot.hasNext
        commands.previousTrackCommand.isEnabled = snapshot.hasPrevious
        commands.changePlaybackPositionCommand.isEnabled = snapshot.duration != nil
    }

    private func register() {
        let commands = MPRemoteCommandCenter.shared()
        add(commands.playCommand) { _ in .setPaused(false) }
        add(commands.pauseCommand) { _ in .setPaused(true) }
        add(commands.togglePlayPauseCommand) { _ in .togglePause }
        add(commands.nextTrackCommand) { _ in .playNext }
        add(commands.previousTrackCommand) { _ in .playPrevious }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]
        add(commands.skipForwardCommand) { event in
            .seekBy((event as? MPSkipIntervalCommandEvent)?.interval ?? 10)
        }
        add(commands.skipBackwardCommand) { event in
            .seekBy(-((event as? MPSkipIntervalCommandEvent)?.interval ?? 10))
        }
        add(commands.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seekTo($0.positionTime) }
        }
    }

    private func add(_ command: MPRemoteCommand, _ translate: @escaping @Sendable (MPRemoteCommandEvent) -> PlayerCommand?) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] event in
            guard let playerCommand = translate(event) else { return .commandFailed }
            // The system calls on the main thread.
            MainActor.assumeIsolated {
                self?.onCommand?(playerCommand)
            }
            return .success
        }
        registrations.append((command, target))
    }

    private func unregister() {
        for registration in registrations {
            registration.command.removeTarget(registration.target)
        }
        registrations = []
    }
}
