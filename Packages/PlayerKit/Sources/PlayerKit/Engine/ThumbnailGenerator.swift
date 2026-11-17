import CoreGraphics
import Foundation
import Libmpv
import os

/// Produces small still frames from a source, for the seek bar's hover preview.
///
/// Uses its own engine instance, separate from the one that is playing: no sound, no
/// window, software decoding, keyframe seeks, and the engine's software renderer drawing
/// straight into a small bitmap. All engine work happens on a private queue.
public final class ThumbnailGenerator: Sendable {
    private let worker: Worker
    private let queue = DispatchQueue(label: "player.thumbnails", qos: .utility)
    /// Number of the newest request. Older ones still waiting in the queue are skipped.
    private let newestRequest = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// - Parameter pixelWidth: Width of the thumbnails; the height follows the video's shape.
    public init(source: PlayableSource, userAgent: String, pixelWidth: Int = 320) {
        worker = Worker(location: source.engineArgument, userAgent: userAgent, pixelWidth: pixelWidth)
    }

    deinit {
        let worker = worker
        queue.async {
            worker.shutDown()
        }
    }

    /// The frame at the keyframe nearest `seconds`, or `nil` if it cannot be produced
    /// (not a video, unreadable, or the engine would not start).
    ///
    /// While the pointer moves along the seek bar requests arrive faster than frames can be
    /// decoded; a request that has been overtaken by a newer one returns `nil` without doing the work.
    public func thumbnail(at seconds: Double) async -> CGImage? {
        let worker = worker
        let newestRequest = newestRequest
        let request = newestRequest.withLock { number in
            number += 1
            return number
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard newestRequest.withLock({ $0 }) == request else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: worker.thumbnail(at: seconds))
            }
        }
    }

    /// Stops the engine and frees its memory. Further requests return `nil`.
    public func shutDown() {
        let worker = worker
        queue.async {
            worker.shutDown()
        }
    }
}

/// The engine instance behind a `ThumbnailGenerator`. Only ever touched on the generator's queue.
private final class Worker: @unchecked Sendable {
    private let location: String
    private let userAgent: String
    private let pixelWidth: Int

    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var isLoaded = false
    private var hasFailed = false
    /// Signalled by the engine (from its own thread) whenever a new frame can be rendered.
    private let frameReady = DispatchSemaphore(value: 0)

    init(location: String, userAgent: String, pixelWidth: Int) {
        self.location = location
        self.userAgent = userAgent
        self.pixelWidth = max(pixelWidth, 16)
    }

    func thumbnail(at seconds: Double) -> CGImage? {
        guard prepare(), let handle, let renderContext else { return nil }

        // Forget everything from earlier requests, or their "seek finished" would be taken for this one's.
        drainFrameSignals()
        while let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE {
            if event.event_id == MPV_EVENT_SHUTDOWN {
                return nil
            }
        }
        var arguments = Self.cStrings(["seek", String(max(seconds, 0)), "absolute+keyframes"])
        defer { Self.free(arguments) }
        guard mpv_command(handle, &arguments) >= 0 else { return nil }

        // The seek is asynchronous. A "frame ready" signal alone is not enough: it can belong to the
        // picture from before the seek. So wait for the engine to report the seek finished, drawing
        // whatever it offers in the meantime (it expects its frames to be consumed), then draw once more.
        let deadline = DispatchTime.now() + .milliseconds(3000)
        var hasRestarted = false
        while DispatchTime.now() < deadline, !hasRestarted {
            if let event = mpv_wait_event(handle, 0.02)?.pointee {
                switch event.event_id {
                case MPV_EVENT_PLAYBACK_RESTART:
                    hasRestarted = true
                case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                    return nil
                default:
                    break
                }
            }
            if mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
                _ = render()
            }
        }
        guard hasRestarted else {
            // The seek is still running and its "restart" would confuse the next request: give up on this source.
            shutDown()
            return nil
        }
        // Give the frame at the new position a moment to arrive, then draw the current picture.
        _ = frameReady.wait(timeout: .now() + .milliseconds(120))
        _ = mpv_render_context_update(renderContext)
        return render()
    }

    func shutDown() {
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
        }
        if let handle {
            mpv_terminate_destroy(handle)
        }
        renderContext = nil
        handle = nil
        hasFailed = true
    }

    // MARK: - Set-up

    /// Starts the engine and opens the file the first time a thumbnail is asked for.
    private func prepare() -> Bool {
        if isLoaded {
            return true
        }
        guard !hasFailed else { return false }
        guard start(), load() else {
            shutDown()
            return false
        }
        isLoaded = true
        return true
    }

    private func start() -> Bool {
        guard let handle = mpv_create() else { return false }
        self.handle = handle
        let options: [(String, String)] = [
            ("config", "no"), ("terminal", "no"), ("ytdl", "no"), ("osc", "no"), ("load-scripts", "no"),
            ("load-stats-overlay", "no"), ("load-osd-console", "no"), ("load-auto-profiles", "no"),
            ("input-default-bindings", "no"), ("osd-level", "0"),
            ("vo", "libmpv"), ("ao", "null"), ("aid", "no"), ("sid", "no"),
            ("pause", "yes"), ("idle", "yes"), ("keep-open", "yes"),
            // Cheap decoding: software only, keyframes only, no loop filter, small buffers.
            ("hwdec", "no"), ("hr-seek", "no"), ("vd-lavc-skiploopfilter", "all"), ("vd-lavc-fast", "yes"),
            ("vd-lavc-threads", "2"), ("demuxer-max-bytes", "8MiB"), ("demuxer-max-back-bytes", "1MiB"),
            ("demuxer-readahead-secs", "0"), ("sws-fast", "yes"),
            ("user-agent", userAgent), ("network-timeout", "15"),
        ]
        for (name, value) in options {
            mpv_set_option_string(handle, name, value)
        }
        guard mpv_initialize(handle) >= 0 else { return false }

        let api = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_SW as NSString).utf8String)
        var parameters = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
            mpv_render_param(),
        ]
        var context: OpaquePointer?
        guard mpv_render_context_create(&context, handle, &parameters) >= 0, let context else { return false }
        renderContext = context
        mpv_render_context_set_update_callback(context, { pointer in
            guard let pointer else { return }
            Unmanaged<DispatchSemaphore>.fromOpaque(pointer).takeUnretainedValue().signal()
        }, Unmanaged.passUnretained(frameReady).toOpaque())
        return true
    }

    /// Opens the file and waits until it is ready to seek in.
    private func load() -> Bool {
        guard let handle else { return false }
        var arguments = Self.cStrings(["loadfile", location, "replace"])
        defer { Self.free(arguments) }
        guard mpv_command(handle, &arguments) >= 0 else { return false }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard let event = mpv_wait_event(handle, 0.25)?.pointee else { continue }
            switch event.event_id {
            // Wait for the first frame, not just for the file to open. Each later seek ends with
            // exactly one "restart" event; if the one from opening were still on its way, the first
            // seek would take it for its own and every thumbnail after that would be one request late.
            case MPV_EVENT_PLAYBACK_RESTART:
                return true
            case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN:
                return false
            default:
                break
            }
            // The engine only reaches its first frame if the frames it offers are consumed.
            if let renderContext, mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
                _ = render()
            }
        }
        return false
    }

    // MARK: - Rendering

    private func render() -> CGImage? {
        guard let handle, let renderContext else { return nil }
        var width: Int64 = 0
        var height: Int64 = 0
        mpv_get_property(handle, "dwidth", MPV_FORMAT_INT64, &width)
        mpv_get_property(handle, "dheight", MPV_FORMAT_INT64, &height)
        guard width > 0, height > 0 else { return nil }

        let outputWidth = pixelWidth
        let outputHeight = max(Int((Double(pixelWidth) * Double(height) / Double(width) / 2).rounded()) * 2, 2)
        let bytesPerRow = outputWidth * 4
        var pixels = Data(count: bytesPerRow * outputHeight)

        var size: [CInt] = [CInt(outputWidth), CInt(outputHeight)]
        var stride = bytesPerRow
        let status: CInt = pixels.withUnsafeMutableBytes { buffer in
            size.withUnsafeMutableBufferPointer { sizePointer in
                "bgr0".withCString { format in
                    withUnsafeMutablePointer(to: &stride) { stridePointer in
                        var parameters = [
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: sizePointer.baseAddress),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stridePointer),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buffer.baseAddress),
                            mpv_render_param(),
                        ]
                        return mpv_render_context_render(renderContext, &parameters)
                    }
                }
            }
        }
        guard status >= 0 else { return nil }
        return FrameImage.make(bgrx: pixels, width: outputWidth, height: outputHeight, bytesPerRow: bytesPerRow)
    }

    private func drainFrameSignals() {
        while frameReady.wait(timeout: .now()) == .success {}
    }

    private static func cStrings(_ strings: [String]) -> [UnsafePointer<CChar>?] {
        strings.map { UnsafePointer(strdup($0)) } + [nil]
    }

    private static func free(_ pointers: [UnsafePointer<CChar>?]) {
        for pointer in pointers {
            Darwin.free(UnsafeMutablePointer(mutating: pointer))
        }
    }
}
