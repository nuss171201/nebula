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

    /// Behind `state` and `playhead`, which decide who is told about a change (see `PlayerModel+State.swift`).
    @ObservationIgnored var storedState = PlaybackState()
    /// Keeps the Mac awake while this player plays.
    @ObservationIgnored let wakefulness = Wakefulness()
    /// What was asked to be opened most recently.
    public internal(set) var source: PlayableSource?
    /// Time from `open` to the first frame of that file being shown.
    public private(set) var timeToFirstFrame: Duration?
    /// The position being dragged to on the seek bar, while the user is dragging.
    public var scrubPosition: Double?

    /// Picture adjustments. Assigning (or changing a field) applies the change to the engine.
    public var video = VideoSettings() {
        didSet {
            apply(video.engineWrites(sourceSize: sourceVideoSize), replacing: oldValue.engineWrites(sourceSize: sourceVideoSize))
            updateSurfaceGeometry()
            updateHDROutput()
        }
    }

    /// Whether the display the player is on can show HDR. Set by whoever owns the window.
    public var displaySupportsHDR = false {
        didSet { updateHDROutput() }
    }

    /// Whether the picture is being sent to the display as HDR right now (rather than
    /// converted to standard range): the video is HDR, the display can show it, and the user allows it.
    public private(set) var isShowingHDR = false

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
                applySpeed()
                report(.speed(speed.value))
            }
        }
    }

    /// Called when the person at the player pauses, resumes, jumps or changes speed themselves.
    @ObservationIgnored public var onPlaybackIntent: (@MainActor (PlaybackIntent) -> Void)?
    /// A factor close to 1 on top of `speed`; see `PlayerModel+Following.swift`.
    @ObservationIgnored public var speedAdjustment = 1.0 {
        didSet {
            if speedAdjustment != oldValue {
                applySpeed()
            }
        }
    }

    @ObservationIgnored var isFollowingExternal = false
    /// When the person's own jump was asked for, until it has landed and been reported.
    @ObservationIgnored var userSeekRequestedAt: ContinuousClock.Instant?

    public internal(set) var abLoop = ABLoop.off

    /// What happens at the end of a file or of the queue. Applied on change.
    public var repeatMode = RepeatMode.off {
        didSet { apply(repeatMode.engineWrites, replacing: oldValue.engineWrites) }
    }

    /// A short message to flash over the picture; see `announce(_:)`.
    public internal(set) var notice: PlayerNotice?
    /// What went wrong with the sound of this file and what was done about it, if anything.
    public internal(set) var audioProblem: String?
    /// What is offered to play next, while the offer stands. Set by whoever makes it.
    public var upNext: UpNextOffer?

    /// The view the video is drawn into; `nil` when the configuration has no video output.
    @ObservationIgnored public let surface: PlayerSurfaceView?
    /// Called once, after the engine has shut down.
    @ObservationIgnored public var onShutdown: (@MainActor () -> Void)?

    @ObservationIgnored let client: MPVClient
    @ObservationIgnored let logger: Logger
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var openedAt: ContinuousClock.Instant?
    @ObservationIgnored private(set) var hasShutDown = false
    @ObservationIgnored let userAgent: String
    @ObservationIgnored let screenshotDirectory: URL
    @ObservationIgnored var noticeCount = 0
    @ObservationIgnored let audioTranscoder: AudioTranscoder?
    @ObservationIgnored var audioFallback = AudioFallbackState()
    @ObservationIgnored var resume = ResumeState()
    @ObservationIgnored let resumesPlayback: Bool
    @ObservationIgnored var thumbnailGenerator: ThumbnailGenerator?
    @ObservationIgnored var thumbnailCache: [Int: CGImage] = [:]
    @ObservationIgnored let memory: (any PlayerMemory)?
    @ObservationIgnored let trackPreferences: TrackPreferences
    /// Memory keys given explicitly for a source (a series id, say), by engine argument.
    @ObservationIgnored var explicitMemoryKeys: [String: [String]] = [:]
    /// Sources (by engine argument) for which no seek-bar stills are made.
    @ObservationIgnored var sourcesWithoutThumbnails: Set<String> = []
    /// Titles given by whoever opened a source (by engine argument), which win over the file's own.
    @ObservationIgnored var givenTitles: [String: String] = [:]
    /// When set, every engine event is appended here (playhead updates left out). A debugging
    /// aid for working out what the engine did in which order; off unless someone turns it on.
    @ObservationIgnored public var eventTrace: [String]?
    @ObservationIgnored private let traceStart = ContinuousClock.now
    /// What is remembered for the file that is open, once it has been looked up.
    @ObservationIgnored var rememberedForCurrentFile = RememberedTracks()
    /// Counts files, so work started for one file is dropped if another has replaced it.
    @ObservationIgnored var fileGeneration = 0
    @ObservationIgnored var selectionTask: Task<Void, Never>?
    @ObservationIgnored var volumeSaveTask: Task<Void, Never>?
    /// The last absolute seek asked for, until it is confirmed to have landed.
    @ObservationIgnored var unconfirmedSeek: (target: Double, retriesLeft: Int)?

    public init(configuration: PlayerConfiguration, memory: (any PlayerMemory)? = nil) throws(PlayerEngineError) {
        let logger = Logger(subsystem: configuration.logSubsystem, category: Self.logCategory)
        self.logger = logger
        self.memory = memory
        userAgent = configuration.userAgent
        screenshotDirectory = configuration.screenshotDirectory
        audioTranscoder = configuration.audioTranscoder
        resumesPlayback = configuration.resumesPlayback
        trackPreferences = configuration.trackPreferences

        let surface = configuration.videoOutput == .surface ? PlayerSurfaceView() : nil
        self.surface = surface
        client = try MPVClient(
            options: configuration.engineOptions,
            windowID: surface.map { Int64(Int(bitPattern: Unmanaged.passUnretained($0.canvasLayer).toOpaque())) },
            keepAlive: surface?.canvasLayer,
            logger: logger
        )

        storedState.volume = configuration.initialVolume
        applyDefaults(configuration.defaults)
        let events = client.events
        eventTask = Task { [weak self] in
            // Restore the volume before any event (and so before any sound) is handled.
            if let volume = await memory?.rememberedVolume() {
                self?.restore(volume)
            }
            for await event in events {
                self?.handle(event)
            }
        }
    }

    // MARK: - Derived values for the UI

    /// The media's own title once known, otherwise the file name or host.
    public var title: String {
        if let source, let given = givenTitles[source.engineArgument] {
            return given
        }
        return state.title ?? source?.displayName ?? ""
    }

    /// The position to show: where the user is dragging to, or the playhead.
    public var displayPosition: Double {
        scrubPosition ?? playhead
    }

    /// The picture's size as shown: after aspect override, crop and rotation.
    public var displayedVideoSize: CGSize? {
        guard let size = state.videoSize else { return nil }
        return video.rotation.swapsDimensions ? CGSize(width: size.height, height: size.width) : size
    }

    /// The selected video track's size in pixels, before any adjustment.
    var sourceVideoSize: CGSize? {
        guard let track = state.selectedTrack(of: .video), let width = track.width, let height = track.height else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: - Intents

    /// Opens a source. `memoryKeys` says under which names track choices are remembered
    /// (most specific first); by default the file and its folder, or the stream's address.
    public func open(_ source: PlayableSource, memoryKeys: [String]? = nil) {
        open(source, options: PlaybackOptions(memoryKeys: memoryKeys))
    }

    /// Opens a source with everything that can be said about how.
    public func open(_ source: PlayableSource, options: PlaybackOptions) {
        if let memoryKeys = options.memoryKeys {
            explicitMemoryKeys[source.engineArgument] = memoryKeys
        }
        givenTitles[source.engineArgument] = options.title
        sourcesWithoutThumbnails.remove(source.engineArgument)
        if !options.generatesThumbnails {
            sourcesWithoutThumbnails.insert(source.engineArgument)
        }
        // Before the state is reset for the new file.
        savePosition()
        resume = ResumeState()
        // A seek in the old file that has not been confirmed yet must not be repeated in the new
        // one: its confirmation can still arrive after this point, and would be taken for a
        // seek that missed (this threw the next episode to its last seconds).
        unconfirmedSeek = nil
        self.source = source
        timeToFirstFrame = nil
        openedAt = .now
        // Show "loading" at once instead of waiting for the engine to say so.
        eventTrace?.append("\(Int((ContinuousClock.now - traceStart) / .milliseconds(1))):open(\(source.displayName))")
        state.apply(.startedLoading)
        // Until the new file shows what it is, it is treated as standard range.
        updateHDROutput()
        client.set("pause", to: .flag(false))
        if let headers = options.headerOption {
            // The fourth argument holds options for this file only; -1 is "no position in the queue".
            client.command(["loadfile", source.engineArgument, "replace", "-1", headers])
        } else {
            client.command(["loadfile", source.engineArgument, "replace"])
        }
    }

    public func setPaused(_ isPaused: Bool) {
        if state.phase == .ended, !isPaused {
            // "Play" on a finished file starts it again from the beginning.
            seek(to: 0)
        }
        client.set("pause", to: .flag(isPaused))
        report(.setPaused(isPaused))
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
        noteSeek()
    }

    /// Moves the playhead by a number of seconds (negative to go back), frame-accurately.
    public func seek(by seconds: Double) {
        guard state.hasMedia else { return }
        unconfirmedSeek = nil
        client.command(["seek", String(seconds), "relative+exact"])
        noteSeek()
    }

    /// Finishes a drag on the seek bar: jump to where the user let go.
    public func commitScrub() {
        guard let target = scrubPosition else { return }
        scrubPosition = nil
        state.position = target
        seek(to: target)
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

    /// Switches the renderer between HDR output and conversion to standard range.
    ///
    /// HDR output is only on while an HDR video is playing: with it on, standard video would be
    /// tagged with a colour space macOS shows with a different gamma, and look washed out.
    private func updateHDROutput() {
        let shouldShowHDR = video.hdrOutput == .automatic && displaySupportsHDR && state.dynamicRange.isHDR
        guard shouldShowHDR != isShowingHDR else { return }
        isShowingHDR = shouldShowHDR
        client.set("target-colorspace-hint", to: .string(shouldShowHDR ? "yes" : "no"))
        surface?.setExtendedDynamicRange(shouldShowHDR)
        logger.notice("hdr-output=\(shouldShowHDR ? "on" : "off", privacy: .public)")
    }

    /// Stops playback and releases the engine. The model cannot be used afterwards.
    public func shutdown() {
        guard !hasShutDown else { return }
        // Where it was left is written now; nothing the engine says while closing may change it.
        savePosition()
        hasShutDown = true
        wakefulness.set(.none)
        discardThumbnails()
        resetAudioFallback()
        client.quit()
    }

    /// Writes an engine property as text. For tests, until the feature has a proper intent.
    func setEngineProperty(_ name: String, to value: String) {
        client.set(name, to: .string(value))
    }

    // MARK: - Events

    /// Adds an event to `eventTrace`, if tracing is on, with the milliseconds since the player
    /// was made; at the moments that matter, also where the engine itself says it is.
    private func trace(_ event: PlayerEvent) {
        guard eventTrace != nil else { return }
        if event.isWorthTracing {
            let milliseconds = Int((ContinuousClock.now - traceStart) / .milliseconds(1))
            eventTrace?.append("\(milliseconds):\(event.traceDescription)")
        }
        if event == .playbackRestarted || event == .fileLoaded || event == .property(.reachedEnd(true)) {
            let details = ["time-pos", "aid", "current-ao", "audio-pts", "pause", "speed"]
                .map { "\($0)=\(client.string($0) ?? "-")" }
                .joined(separator: " ")
            eventTrace?.append("[\(details)]")
        }
    }

    private func handle(_ event: PlayerEvent) {
        trace(event)
        let previousSourceSize = sourceVideoSize
        if event == .startedLoading {
            // The engine is moving on by itself (next in queue): note where this file was left.
            savePosition()
            resume = ResumeState()
        }
        state.apply(event)
        // The surface shows the part of its canvas the video occupies, so it needs the video's size.
        updateSurfaceGeometry()
        updateHDROutput()
        // A crop is a ratio; its rectangle depends on the source size, which has just become known or changed.
        if video.crop != .source, sourceVideoSize != previousSourceSize {
            client.set("video-crop", to: .string(VideoSettings.cropValue(video.crop, sourceSize: sourceVideoSize)))
        }

        switch event {
        case .startedLoading:
            discardThumbnails()
            resetAudioFallback()
            unconfirmedSeek = nil
            // A loop belongs to one file.
            if abLoop != .off {
                setABLoop(.off)
            }
        case .fileLoaded:
            selectTracksForLoadedFile()
        case let .property(.playlist(entries)):
            // The engine moved on by itself (next in queue): keep `source` pointing at what is playing.
            if let current = entries.first(where: \.isCurrent), current.location != source?.engineArgument,
               let playing = try? PlayableSource(userInput: current.location) {
                source = playing
            }
        case .property(.tracks):
            checkAudioDecoding()
        case .property(.position):
            savePositionIfDue()
        case .property(.paused(true)), .ended(.reachedEnd), .property(.reachedEnd(true)):
            savePosition()
        case .playbackRestarted:
            confirmSeek()
            reportLandedSeek()
            checkAudioDecoding()
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
            wakefulness.set(.none)
            eventTask = nil
            onShutdown?()
            onShutdown = nil
        default:
            break
        }
    }
}
