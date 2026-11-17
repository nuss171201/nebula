import Foundation
import Observation
import os

/// One player: owns the playback engine and its video surface, publishes what is
/// happening as `state`, and turns user intents into engine commands.
@MainActor
@Observable
public final class PlayerModel {
    public static let logCategory = "player"

    public private(set) var state = PlaybackState()
    /// What was asked to be opened most recently.
    public private(set) var source: PlayableSource?
    /// Time from `open` to the first frame of that file being shown.
    public private(set) var timeToFirstFrame: Duration?
    /// The position being dragged to on the seek bar, while the user is dragging.
    public var scrubPosition: Double?

    /// The view the video is drawn into; `nil` when the configuration has no video output.
    @ObservationIgnored public let surface: PlayerSurfaceView?
    /// Called once, after the engine has shut down.
    @ObservationIgnored public var onShutdown: (@MainActor () -> Void)?

    @ObservationIgnored private let client: MPVClient
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var openedAt: ContinuousClock.Instant?
    @ObservationIgnored private var hasShutDown = false

    public init(configuration: PlayerConfiguration) throws(PlayerEngineError) {
        let logger = Logger(subsystem: configuration.logSubsystem, category: Self.logCategory)
        self.logger = logger

        let surface = configuration.videoOutput == .surface ? PlayerSurfaceView() : nil
        self.surface = surface
        client = try MPVClient(
            options: configuration.engineOptions,
            windowID: surface.map { Int64(Int(bitPattern: Unmanaged.passUnretained($0.canvasLayer).toOpaque())) },
            keepAlive: surface?.canvasLayer,
            logger: logger
        )

        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    // MARK: - Derived values for the UI

    /// The media's own title once known, otherwise the file name or host.
    public var title: String {
        state.title ?? source?.displayName ?? ""
    }

    /// The position to show: where the user is dragging to, or the playhead.
    public var displayPosition: Double {
        scrubPosition ?? state.position
    }

    // MARK: - Intents

    public func open(_ source: PlayableSource) {
        self.source = source
        timeToFirstFrame = nil
        openedAt = .now
        // Show "loading" at once instead of waiting for the engine to say so.
        state.apply(.startedLoading)
        client.set("pause", to: .flag(false))
        client.command(["loadfile", source.engineArgument, "replace"])
    }

    public func setPaused(_ isPaused: Bool) {
        if state.phase == .ended, !isPaused {
            // "Play" on a finished file starts it again from the beginning.
            seek(to: 0)
        }
        client.set("pause", to: .flag(isPaused))
    }

    public func togglePause() {
        setPaused(state.phase == .ended ? false : !state.isPaused)
    }

    /// Jumps to an absolute position in seconds, clamped to the file.
    ///
    /// Exact rather than to the nearest keyframe: keyframes can be many seconds apart,
    /// and landing somewhere other than where the user pointed feels broken.
    public func seek(to seconds: Double) {
        guard state.hasMedia else { return }
        let target = min(max(seconds, 0), state.duration ?? .greatestFiniteMagnitude)
        client.command(["seek", String(target), "absolute+exact"])
    }

    /// Moves the playhead by a number of seconds (negative to go back), frame-accurately.
    public func seek(by seconds: Double) {
        guard state.hasMedia else { return }
        client.command(["seek", String(seconds), "relative+exact"])
    }

    /// Finishes a drag on the seek bar: jump to where the user let go.
    public func commitScrub() {
        guard let target = scrubPosition else { return }
        scrubPosition = nil
        state.position = target
        seek(to: target)
    }

    /// Sets the volume, 0–100.
    public func setVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 100)
        state.volume = clamped
        client.set("volume", to: .double(clamped))
        if clamped > 0, state.isMuted {
            setMuted(false)
        }
    }

    public func setMuted(_ isMuted: Bool) {
        state.isMuted = isMuted
        client.set("mute", to: .flag(isMuted))
    }

    public func toggleMute() {
        setMuted(!state.isMuted)
    }

    /// Closes the current file but keeps the player ready for another.
    public func stop() {
        client.command(["stop"])
    }

    /// Runs a command that only concerns playback. Window commands return `false`
    /// so the caller (the window) can handle them.
    @discardableResult
    public func perform(_ command: PlayerCommand) -> Bool {
        switch command {
        case .togglePause: togglePause()
        case let .seekBy(seconds): seek(by: seconds)
        case let .changeVolumeBy(amount): setVolume(state.volume + amount)
        case .toggleMute: toggleMute()
        case .toggleFullScreen, .exitFullScreen: return false
        }
        return true
    }

    /// Stops playback and releases the engine. The model cannot be used afterwards.
    public func shutdown() {
        guard !hasShutDown else { return }
        hasShutDown = true
        client.quit()
    }

    /// Reads an engine property as text. Blocks briefly; for diagnostics and tests only.
    func engineProperty(_ name: String) -> String? {
        client.string(name)
    }

    /// Writes an engine property as text. For tests, until the feature has a proper intent.
    func setEngineProperty(_ name: String, to value: String) {
        client.set(name, to: .string(value))
    }

    // MARK: - Events

    private func handle(_ event: PlayerEvent) {
        state.apply(event)
        // The surface shows the part of its canvas the video occupies, so it needs the video's size.
        surface?.videoSize = state.videoSize

        switch event {
        case .playbackRestarted:
            if let openedAt, timeToFirstFrame == nil {
                let elapsed = ContinuousClock.now - openedAt
                timeToFirstFrame = elapsed
                let milliseconds = Int((elapsed / .milliseconds(1)).rounded())
                let kind = source?.isLocalFile == true ? "file" : "network"
                logger.notice("first-frame-ms=\(milliseconds, privacy: .public) source=\(kind, privacy: .public)")
            }
        case let .property(.hardwareDecoder(decoder)):
            // Worth a log line: software decoding of 4K costs several times the CPU and memory.
            if state.hasMedia || state.phase == .loading {
                logger.notice("decoder=\(decoder ?? "software", privacy: .public)")
            }
        case let .ended(.failed(message)):
            logger.error("playback failed: \(message, privacy: .public)")
        case .shutdown:
            hasShutDown = true
            eventTask = nil
            onShutdown?()
            onShutdown = nil
        default:
            break
        }
    }
}
