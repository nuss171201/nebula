import CoreGraphics
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

    /// Picture adjustments. Assigning (or changing a field) applies the change to the engine.
    public var video = VideoSettings() {
        didSet {
            apply(video.engineWrites(sourceSize: sourceVideoSize), replacing: oldValue.engineWrites(sourceSize: sourceVideoSize))
            updateSurfaceGeometry()
        }
    }

    /// Sound adjustments, applied on change.
    public var audio = AudioSettings() {
        didSet { apply(audio.engineWrites(), replacing: oldValue.engineWrites()) }
    }

    /// Subtitle timing and appearance, applied on change.
    public var subtitles = SubtitleSettings() {
        didSet { apply(subtitles.engineWrites(), replacing: oldValue.engineWrites()) }
    }

    /// Playback rate, applied on change.
    public var speed = PlaybackSpeed.normal {
        didSet {
            if speed != oldValue {
                client.set("speed", to: .double(speed.value))
            }
        }
    }

    public private(set) var abLoop = ABLoop.off

    /// The view the video is drawn into; `nil` when the configuration has no video output.
    @ObservationIgnored public let surface: PlayerSurfaceView?
    /// Called once, after the engine has shut down.
    @ObservationIgnored public var onShutdown: (@MainActor () -> Void)?

    @ObservationIgnored private let client: MPVClient
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var openedAt: ContinuousClock.Instant?
    @ObservationIgnored private var hasShutDown = false
    /// The last absolute seek asked for, until it is confirmed to have landed.
    @ObservationIgnored private var unconfirmedSeek: (target: Double, retriesLeft: Int)?

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

    /// The picture's size as shown: after aspect override, crop and rotation.
    public var displayedVideoSize: CGSize? {
        guard let size = state.videoSize else { return nil }
        return video.rotation.swapsDimensions ? CGSize(width: size.height, height: size.width) : size
    }

    /// The selected video track's size in pixels, before any adjustment.
    private var sourceVideoSize: CGSize? {
        guard let track = state.selectedTrack(of: .video), let width = track.width, let height = track.height else { return nil }
        return CGSize(width: width, height: height)
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
        unconfirmedSeek = (target, 1)
        client.command(["seek", String(target), "absolute+exact"])
    }

    /// Moves the playhead by a number of seconds (negative to go back), frame-accurately.
    public func seek(by seconds: Double) {
        guard state.hasMedia else { return }
        unconfirmedSeek = nil
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

    // MARK: - Tracks, chapters, queue

    /// Switches to a track, or turns that kind of track off with `nil`.
    public func selectTrack(_ kind: MediaTrack.Kind, number: Int?) {
        let property = switch kind {
        case .video: "vid"
        case .audio: "aid"
        case .subtitle: "sid"
        }
        client.set(property, to: .string(number.map(String.init) ?? "no"))
    }

    public func seek(toChapter index: Int) {
        guard state.chapters.indices.contains(index) else { return }
        client.set("chapter", to: .int(Int64(index)))
    }

    public func nextChapter() {
        client.command(["add", "chapter", "1"])
    }

    public func previousChapter() {
        client.command(["add", "chapter", "-1"])
    }

    /// Replaces the queue with these sources, in this order, and starts playing the one at `index`.
    public func open(_ sources: [PlayableSource], startingAt index: Int = 0) {
        guard !sources.isEmpty else { return }
        let start = sources.indices.contains(index) ? index : 0
        open(sources[start])
        for source in sources[(start + 1)...] {
            client.command(["loadfile", source.engineArgument, "append"])
        }
        // Items before the starting one are appended and then moved in front of it, in order.
        let countFromStart = sources.count - start
        for (offset, source) in sources[..<start].enumerated() {
            client.command(["loadfile", source.engineArgument, "append"])
            client.command(["playlist-move", String(countFromStart + offset), String(offset)])
        }
    }

    /// Adds a source to the end of the queue without interrupting playback.
    public func enqueue(_ source: PlayableSource) {
        client.command(["loadfile", source.engineArgument, state.hasMedia || state.phase == .loading ? "append" : "append-play"])
    }

    public func playNext() {
        client.command(["playlist-next", "weak"])
    }

    public func playPrevious() {
        client.command(["playlist-prev", "weak"])
    }

    public func play(queueIndex index: Int) {
        guard state.playlist.indices.contains(index) else { return }
        client.command(["playlist-play-index", String(index)])
    }

    // MARK: - Stepping and looping

    /// Advances one frame and pauses.
    public func stepFrameForward() {
        client.command(["frame-step"])
    }

    /// Goes back one frame and pauses.
    public func stepFrameBackward() {
        client.command(["frame-back-step"])
    }

    /// Marks the loop start, then the loop end, then clears the loop.
    public func cycleABLoop() {
        setABLoop(abLoop.advanced(at: state.position))
    }

    public func setABLoop(_ loop: ABLoop) {
        abLoop = loop
        for write in loop.engineWrites {
            client.set(write.name, to: write.value)
        }
    }

    // MARK: - Still frames

    /// The current frame at the video's own resolution, with or without subtitles.
    public func captureFrame(includingSubtitles: Bool) async -> CGImage? {
        guard state.hasMedia else { return nil }
        let client = client
        let mode = includingSubtitles ? "subtitles" : "video"
        let node = await Task.detached(priority: .userInitiated) {
            client.commandResult(["screenshot-raw", mode])
        }.value
        return node.flatMap(FrameImage.make(from:))
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
        case .stepFrameForward: stepFrameForward()
        case .stepFrameBackward: stepFrameBackward()
        case .speedUp: speed = speed.steppedUp()
        case .slowDown: speed = speed.steppedDown()
        case .resetSpeed: speed = .normal
        case .nextChapter: nextChapter()
        case .previousChapter: previousChapter()
        case .playNext: playNext()
        case .playPrevious: playPrevious()
        case .cycleABLoop: cycleABLoop()
        case .toggleSubtitles: subtitles.isVisible.toggle()
        case let .shiftAudioDelay(seconds): audio.delay = ((audio.delay + seconds) * 1000).rounded() / 1000
        case let .shiftSubtitleDelay(seconds): subtitles.delay = ((subtitles.delay + seconds) * 1000).rounded() / 1000
        case let .cycleTrack(kind): cycleTrack(kind)
        default: return false
        }
        return true
    }

    /// Selects the next track of a kind, wrapping round; subtitles also pass through "off".
    private func cycleTrack(_ kind: MediaTrack.Kind) {
        let tracks = state.tracks(of: kind)
        guard !tracks.isEmpty else { return }
        let current = tracks.firstIndex { $0.isSelected }
        switch (kind, current) {
        case (_, nil):
            selectTrack(kind, number: tracks[0].number)
        case let (.subtitle, index?) where index == tracks.count - 1:
            selectTrack(kind, number: nil)
        case let (_, index?):
            selectTrack(kind, number: tracks[(index + 1) % tracks.count].number)
        }
    }

    /// Checks that an absolute seek landed where it was aimed, and repeats it once if not.
    ///
    /// A seek issued while the engine is still re-reading the file after a track switch can end
    /// up on the next keyframe, seconds away from its target (reproduced reliably with this
    /// engine build). Opening a file, restoring its tracks and resuming is exactly that sequence.
    private func confirmSeek() {
        guard let seek = unconfirmedSeek else { return }
        unconfirmedSeek = nil
        guard let landed = client.string("time-pos").flatMap(Double.init) else { return }
        let reachable = min(seek.target, max((state.duration ?? seek.target) - 0.5, 0))
        if abs(landed - reachable) > 0.75, seek.retriesLeft > 0 {
            logger.notice("seek to \(seek.target, privacy: .public) landed at \(landed, privacy: .public); repeating")
            unconfirmedSeek = (seek.target, seek.retriesLeft - 1)
            client.command(["seek", String(seek.target), "absolute+exact"])
        }
    }

    /// Sends the engine only the values that differ from what it already has.
    private func apply(_ writes: [EngineWrite], replacing previous: [EngineWrite]) {
        for write in writes where !previous.contains(write) {
            client.set(write.name, to: write.value)
        }
    }

    private func updateSurfaceGeometry() {
        surface?.videoSize = displayedVideoSize
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

    /// Runs an engine command and returns its result. Blocks; for tests and off-main work.
    func engineCommandResult(_ arguments: [String]) -> MPVNode? {
        client.commandResult(arguments)
    }

    /// Writes an engine property as text. For tests, until the feature has a proper intent.
    func setEngineProperty(_ name: String, to value: String) {
        client.set(name, to: .string(value))
    }

    // MARK: - Events

    private func handle(_ event: PlayerEvent) {
        let previousSourceSize = sourceVideoSize
        state.apply(event)
        // The surface shows the part of its canvas the video occupies, so it needs the video's size.
        updateSurfaceGeometry()
        // A crop is a ratio; its rectangle depends on the source size, which has just become known or changed.
        if video.crop != .source, sourceVideoSize != previousSourceSize {
            client.set("video-crop", to: .string(VideoSettings.cropValue(video.crop, sourceSize: sourceVideoSize)))
        }

        switch event {
        case .startedLoading:
            unconfirmedSeek = nil
            // A loop belongs to one file.
            if abLoop != .off {
                setABLoop(.off)
            }
        case let .property(.playlist(entries)):
            // The engine moved on by itself (next in queue): keep `source` pointing at what is playing.
            if let current = entries.first(where: \.isCurrent), current.location != source?.engineArgument,
               let playing = try? PlayableSource(userInput: current.location) {
                source = playing
            }
        case .playbackRestarted:
            confirmSeek()
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
