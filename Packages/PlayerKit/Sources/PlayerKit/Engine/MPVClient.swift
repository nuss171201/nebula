import Foundation
import Libmpv
import os

/// Why the playback engine could not be started.
public enum PlayerEngineError: Error, Sendable, Equatable {
    case couldNotCreate
    case couldNotInitialize(String)

    public var userMessage: String {
        switch self {
        case .couldNotCreate: "The playback engine could not be started."
        case let .couldNotInitialize(reason): "The playback engine could not be started (\(reason))."
        }
    }
}

/// A value to write to an engine property.
enum MPVValue: Sendable, Equatable {
    case flag(Bool)
    case double(Double)
    case int(Int64)
    case string(String)
    case node(MPVNode)
}

/// The engine properties the app watches, and how each one is read.
enum ObservedProperty: UInt64, CaseIterable, Sendable {
    case pause = 1, timePosition, duration, volume, mute, pausedForCache, seeking, endOfFileReached
    case mediaTitle, displayWidth, displayHeight, hardwareDecoder, cacheDuration
    case trackList, chapterList, chapter, playlist, videoTransfer

    var name: String {
        switch self {
        case .pause: "pause"
        case .timePosition: "time-pos"
        case .duration: "duration"
        case .volume: "volume"
        case .mute: "mute"
        case .pausedForCache: "paused-for-cache"
        case .seeking: "seeking"
        case .endOfFileReached: "eof-reached"
        case .mediaTitle: "media-title"
        case .displayWidth: "dwidth"
        case .displayHeight: "dheight"
        case .hardwareDecoder: "hwdec-current"
        case .cacheDuration: "demuxer-cache-duration"
        case .trackList: "track-list"
        case .chapterList: "chapter-list"
        case .chapter: "chapter"
        case .playlist: "playlist"
        case .videoTransfer: "video-params/gamma"
        }
    }

    var format: mpv_format {
        switch self {
        case .pause, .mute, .pausedForCache, .seeking, .endOfFileReached: MPV_FORMAT_FLAG
        case .timePosition, .duration, .volume, .cacheDuration: MPV_FORMAT_DOUBLE
        case .displayWidth, .displayHeight, .chapter: MPV_FORMAT_INT64
        case .mediaTitle, .hardwareDecoder, .videoTransfer: MPV_FORMAT_STRING
        case .trackList, .chapterList, .playlist: MPV_FORMAT_NODE
        }
    }

    /// Values that change many times a second and are only needed for display.
    var isHighFrequency: Bool {
        self == .timePosition || self == .cacheDuration
    }

    /// Translates a raw value into the app's vocabulary. `nil` value means "unavailable".
    func property(for value: MPVValue?) -> PlayerProperty? {
        switch (self, value) {
        case let (.pause, .flag(flag)): .paused(flag)
        case let (.mute, .flag(flag)): .muted(flag)
        case let (.pausedForCache, .flag(flag)): .waitingForData(flag)
        case let (.seeking, .flag(flag)): .seeking(flag)
        case let (.endOfFileReached, .flag(flag)): .reachedEnd(flag)
        case (.endOfFileReached, nil): .reachedEnd(false)
        case let (.timePosition, .double(seconds)): .position(seconds)
        case (.timePosition, nil): .position(nil)
        case let (.duration, .double(seconds)): .duration(seconds)
        case (.duration, nil): .duration(nil)
        case let (.volume, .double(level)): .volume(level)
        case let (.cacheDuration, .double(seconds)): .bufferedAhead(seconds)
        case (.cacheDuration, nil): .bufferedAhead(nil)
        case let (.displayWidth, .int(pixels)): .displayWidth(Int(pixels))
        case (.displayWidth, nil): .displayWidth(nil)
        case let (.displayHeight, .int(pixels)): .displayHeight(Int(pixels))
        case (.displayHeight, nil): .displayHeight(nil)
        case let (.mediaTitle, .string(text)): .title(text.isEmpty ? nil : text)
        case (.mediaTitle, nil): .title(nil)
        // The engine reports "no" (or nothing) when it is decoding in software.
        case let (.hardwareDecoder, .string(text)): .hardwareDecoder(text.isEmpty || text == "no" ? nil : text)
        case (.hardwareDecoder, nil): .hardwareDecoder(nil)
        case let (.trackList, .node(node)): .tracks(MediaTrack.list(from: node))
        case (.trackList, nil): .tracks([])
        case let (.chapterList, .node(node)): .chapters(MediaChapter.list(from: node))
        case (.chapterList, nil): .chapters([])
        // The engine reports -1 before the first chapter starts.
        case let (.chapter, .int(index)): .currentChapter(index >= 0 ? Int(index) : nil)
        case (.chapter, nil): .currentChapter(nil)
        case let (.playlist, .node(node)): .playlist(PlaylistEntry.list(from: node))
        case (.playlist, nil): .playlist([])
        case let (.videoTransfer, .string(name)): .transferFunction(name.isEmpty ? nil : name)
        case (.videoTransfer, nil): .transferFunction(nil)
        default: nil
        }
    }
}

/// The engine handle. libmpv's client API is thread-safe, so the pointer may cross threads.
private struct EngineHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

/// Keeps a non-Sendable object alive across threads without ever touching it.
private struct Retained: @unchecked Sendable {
    let object: AnyObject?
}

/// A thin, thread-safe wrapper around one libmpv instance.
///
/// Outgoing calls are asynchronous and never block the caller. Incoming events are
/// translated to `PlayerEvent` values on a dedicated thread and delivered through `events`.
final class MPVClient: Sendable {
    let events: AsyncStream<PlayerEvent>
    private let core: Core

    /// - Parameters:
    ///   - options: Engine options, applied in order before initialisation.
    ///   - windowID: Address of the `CAMetalLayer` to render into, if any.
    ///   - keepAlive: Kept alive until the engine has fully shut down (the layer above).
    init(
        options: [(name: String, value: String)],
        windowID: Int64?,
        keepAlive: AnyObject?,
        logger: Logger
    ) throws(PlayerEngineError) {
        guard let handle = mpv_create() else { throw .couldNotCreate }

        for (name, value) in options {
            let status = mpv_set_option_string(handle, name, value)
            if status < 0 {
                // An option this build does not know is not fatal; say so and carry on.
                let reason = Self.describe(status)
                logger.warning("option \(name, privacy: .public)=\(value, privacy: .public) rejected: \(reason, privacy: .public)")
            }
        }
        if var windowID {
            mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &windowID)
        }
        mpv_request_log_messages(handle, "warn")

        let status = mpv_initialize(handle)
        guard status >= 0 else {
            mpv_terminate_destroy(handle)
            throw .couldNotInitialize(Self.describe(status))
        }
        for property in ObservedProperty.allCases {
            mpv_observe_property(handle, property.rawValue, property.name, property.format)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: PlayerEvent.self)
        events = stream
        let core = Core(handle: handle, keepAlive: Retained(object: keepAlive))
        self.core = core

        let engine = EngineHandle(pointer: handle)
        let thread = Thread {
            core.runEventLoop(handle: engine.pointer, continuation: continuation, logger: logger)
        }
        thread.name = "player.mpv.events"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        core.quit()
    }

    /// Runs an engine command, for example `["loadfile", path]`.
    func command(_ arguments: [String]) {
        core.withHandle { handle in
            var pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
            pointers.append(nil)
            mpv_command_async(handle, 0, &pointers)
            for pointer in pointers {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
    }

    func set(_ name: String, to value: MPVValue) {
        core.withHandle { handle in
            switch value {
            case let .flag(flag):
                var raw: CInt = flag ? 1 : 0
                mpv_set_property_async(handle, 0, name, MPV_FORMAT_FLAG, &raw)
            case let .double(number):
                var raw = number
                mpv_set_property_async(handle, 0, name, MPV_FORMAT_DOUBLE, &raw)
            case let .int(number):
                var raw = number
                mpv_set_property_async(handle, 0, name, MPV_FORMAT_INT64, &raw)
            case let .string(text):
                text.withCString { pointer in
                    var raw: UnsafePointer<CChar>? = pointer
                    _ = mpv_set_property_async(handle, 0, name, MPV_FORMAT_STRING, &raw)
                }
            case .node:
                // Structured values are only ever read from the engine.
                break
            }
        }
    }

    /// Reads a structured property. Blocks briefly.
    func node(_ name: String) -> MPVNode? {
        core.read { handle in
            var result = mpv_node()
            guard mpv_get_property(handle, name, MPV_FORMAT_NODE, &result) >= 0 else { return nil }
            defer { mpv_free_node_contents(&result) }
            return MPVNode(result)
        }
    }

    /// Runs a command and waits for its result. Blocks until the engine has finished it, so it
    /// must not be called from the main thread for anything slow.
    func commandResult(_ arguments: [String]) -> MPVNode? {
        core.read { handle in
            var pointers: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
            pointers.append(nil)
            defer {
                for pointer in pointers {
                    free(UnsafeMutablePointer(mutating: pointer))
                }
            }
            var result = mpv_node()
            guard mpv_command_ret(handle, &pointers, &result) >= 0 else { return nil }
            defer { mpv_free_node_contents(&result) }
            return MPVNode(result)
        }
    }

    /// Reads a property as text. Blocks briefly; meant for diagnostics and tests, not for UI.
    func string(_ name: String) -> String? {
        core.read { handle in
            guard let pointer = mpv_get_property_string(handle, name) else { return nil }
            defer { mpv_free(pointer) }
            return String(cString: pointer)
        }
    }

    /// Asks the engine to stop and release everything. `events` ends with `.shutdown`.
    func quit() {
        core.quit()
    }

    private static func describe(_ status: CInt) -> String {
        String(cString: mpv_error_string(status))
    }
}

// MARK: - Core

/// Owns the engine handle. Lives until the event thread has destroyed the engine,
/// independently of the `MPVClient` that created it.
private final class Core: @unchecked Sendable {
    /// Serialises outgoing calls with the moment the handle goes away.
    private let queue = DispatchQueue(label: "player.mpv.calls", qos: .userInitiated)
    /// Only read or written on `queue`.
    private var handle: OpaquePointer?
    private let keepAlive: Retained

    init(handle: OpaquePointer, keepAlive: Retained) {
        self.handle = handle
        self.keepAlive = keepAlive
    }

    func withHandle(_ body: @escaping @Sendable (OpaquePointer) -> Void) {
        queue.async {
            if let handle = self.handle {
                body(handle)
            }
        }
    }

    func read<Value: Sendable>(_ body: @Sendable (OpaquePointer) -> Value?) -> Value? {
        queue.sync {
            handle.flatMap(body)
        }
    }

    func quit() {
        withHandle { handle in
            mpv_command_string(handle, "quit")
        }
    }

    /// Runs on the event thread until the engine shuts down, then destroys it.
    func runEventLoop(handle: OpaquePointer, continuation: AsyncStream<PlayerEvent>.Continuation, logger: Logger) {
        // High-frequency values (the playhead) are forwarded at display rate, not at frame rate.
        // The newest value is never lost: one that arrives too soon is held and sent as soon
        // as the interval has passed, even if nothing else happens (for example, a seek while paused).
        var lastSent: [ObservedProperty: ContinuousClock.Instant] = [:]
        var held: [ObservedProperty: PlayerProperty] = [:]
        let interval = MPVClientTiming.displayUpdateInterval

        func flushHeld(now: ContinuousClock.Instant) {
            for (observed, property) in held where now - (lastSent[observed] ?? now - interval) >= interval {
                held[observed] = nil
                lastSent[observed] = now
                continuation.yield(.property(property))
            }
        }

        eventLoop: while true {
            // Wait indefinitely unless a held value needs sending soon.
            let timeout = held.isEmpty ? -1 : MPVClientTiming.displayUpdateSeconds
            guard let event = mpv_wait_event(handle, timeout)?.pointee else { continue }
            defer { flushHeld(now: .now) }

            switch event.event_id {
            case MPV_EVENT_SHUTDOWN:
                break eventLoop
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let observed = ObservedProperty(rawValue: event.reply_userdata),
                      let data = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                      let property = observed.property(for: Self.value(of: data))
                else { continue }
                if observed.isHighFrequency {
                    let now = ContinuousClock.now
                    if let last = lastSent[observed], now - last < interval {
                        held[observed] = property
                        continue
                    }
                    held[observed] = nil
                    lastSent[observed] = now
                }
                continuation.yield(.property(property))
            case MPV_EVENT_LOG_MESSAGE:
                if let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                    let prefix = String(cString: message.prefix)
                    let text = String(cString: message.text).trimmingCharacters(in: .newlines)
                    logger.warning("[\(prefix, privacy: .public)] \(text, privacy: .public)")
                }
            default:
                if let lifecycle = Self.lifecycleEvent(for: event) {
                    continuation.yield(lifecycle)
                }
            }
        }

        continuation.yield(.shutdown)
        continuation.finish()

        // No call may be in flight or follow once the handle is destroyed.
        queue.sync {
            self.handle = nil
        }
        mpv_terminate_destroy(handle)

        // The render target can go now that nothing draws into it. UI objects are released on the main thread.
        let keepAlive = keepAlive
        DispatchQueue.main.async {
            _ = keepAlive
        }
    }

    /// The events that mark a file starting, becoming ready, showing a frame, or stopping.
    private static func lifecycleEvent(for event: mpv_event) -> PlayerEvent? {
        switch event.event_id {
        case MPV_EVENT_START_FILE:
            return .startedLoading
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestarted
        case MPV_EVENT_END_FILE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { return nil }
            return .ended(endReason(data))
        default:
            return nil
        }
    }

    private static func value(of property: mpv_event_property) -> MPVValue? {
        guard let data = property.data else { return nil }
        switch property.format {
        case MPV_FORMAT_FLAG:
            return .flag(data.assumingMemoryBound(to: CInt.self).pointee != 0)
        case MPV_FORMAT_DOUBLE:
            return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_INT64:
            return .int(data.assumingMemoryBound(to: Int64.self).pointee)
        case MPV_FORMAT_STRING:
            guard let text = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return nil }
            return .string(String(cString: text))
        case MPV_FORMAT_NODE:
            return .node(MPVNode(data.assumingMemoryBound(to: mpv_node.self).pointee))
        default:
            return nil
        }
    }

    private static func endReason(_ data: mpv_event_end_file) -> PlaybackEndReason {
        switch data.reason {
        case MPV_END_FILE_REASON_EOF:
            .reachedEnd
        case MPV_END_FILE_REASON_ERROR:
            .failed(failureMessage(for: data.error))
        default:
            .stopped
        }
    }

    private static func failureMessage(for error: CInt) -> String {
        switch mpv_error(rawValue: error) {
        case MPV_ERROR_LOADING_FAILED:
            "The file or address could not be opened."
        case MPV_ERROR_UNKNOWN_FORMAT:
            "This file is not in a format that can be played."
        case MPV_ERROR_NOTHING_TO_PLAY:
            "This file has no audio or video to play."
        case MPV_ERROR_AO_INIT_FAILED:
            "The audio output could not be started."
        case MPV_ERROR_VO_INIT_FAILED:
            "The video output could not be started."
        default:
            "Playback failed (\(String(cString: mpv_error_string(error))))."
        }
    }
}

private enum MPVClientTiming {
    /// How often high-frequency values (the playhead) are forwarded: about 15 times a second.
    static let displayUpdateSeconds = 0.066
    static let displayUpdateInterval: Duration = .milliseconds(66)
}
