import CoreGraphics
import Foundation

/// Why a file stopped playing.
public enum PlaybackEndReason: Sendable, Equatable {
    case reachedEnd
    /// Stopped on request, or replaced by another file.
    case stopped
    /// Carries a sentence that can be shown to the user.
    case failed(String)
}

/// A change to one observed player value. `nil` means the value is currently unavailable
/// (for example, no duration for a live stream).
public enum PlayerProperty: Sendable, Equatable {
    case paused(Bool)
    case position(Double?)
    case duration(Double?)
    case volume(Double)
    case muted(Bool)
    /// Playback is stalled waiting for data.
    case waitingForData(Bool)
    case seeking(Bool)
    /// With "keep open", the player pauses on the last frame and reports this instead of ending.
    case reachedEnd(Bool)
    case title(String?)
    /// The video's display size in pixels, after aspect-ratio correction.
    case displayWidth(Int?)
    case displayHeight(Int?)
    /// The hardware decoder in use, or `nil` when decoding in software.
    case hardwareDecoder(String?)
    /// Seconds of media buffered ahead of the playhead.
    case bufferedAhead(Double?)
    case tracks([MediaTrack])
    case chapters([MediaChapter])
    /// The chapter the playhead is in; `nil` before the first one.
    case currentChapter(Int?)
    case playlist([PlaylistEntry])
}

/// Everything the player reports, as values.
public enum PlayerEvent: Sendable, Equatable {
    case startedLoading
    case fileLoaded
    /// The first frame after loading or seeking is on screen.
    case playbackRestarted
    case ended(PlaybackEndReason)
    case property(PlayerProperty)
    /// The engine has shut down; no further events follow.
    case shutdown
}

/// What the player is doing, derived purely from the events it has reported.
public struct PlaybackState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Nothing is open.
        case idle
        case loading
        /// A file is open; see `isPaused` and `isWaitingForData` for the detail.
        case playing
        /// Playback reached the end of the file.
        case ended
        case failed(String)
    }

    public var phase: Phase = .idle
    public var isPaused = false
    public var isWaitingForData = false
    public var isSeeking = false
    /// Seconds from the start.
    public var position: Double = 0
    /// Seconds; `nil` when unknown (live streams) or nothing is open.
    public var duration: Double?
    /// 0–100.
    public var volume: Double = 100
    public var isMuted = false
    public var title: String?
    public var hardwareDecoder: String?
    public var bufferedAhead: Double?
    /// Whether a frame of the current file has been shown yet.
    public var hasShownFirstFrame = false
    public var tracks: [MediaTrack] = []
    public var chapters: [MediaChapter] = []
    public var currentChapter: Int?
    /// The play queue. Survives from one file to the next.
    public var playlist: [PlaylistEntry] = []

    private var displayWidth: Int?
    private var displayHeight: Int?

    public init() {}

    /// The video's display size, once both dimensions are known.
    public var videoSize: CGSize? {
        guard let displayWidth, let displayHeight, displayWidth > 0, displayHeight > 0 else { return nil }
        return CGSize(width: displayWidth, height: displayHeight)
    }

    public func tracks(of kind: MediaTrack.Kind) -> [MediaTrack] {
        tracks.filter { $0.kind == kind }
    }

    public func selectedTrack(of kind: MediaTrack.Kind) -> MediaTrack? {
        tracks.first { $0.kind == kind && $0.isSelected }
    }

    /// The chapter that contains a position, if the file has chapters.
    public func chapter(at seconds: Double) -> MediaChapter? {
        chapters.last { $0.start <= seconds + 0.001 }
    }

    /// Whether a file is open (playing, paused or sitting on its last frame).
    public var hasMedia: Bool {
        phase == .playing || phase == .ended
    }

    /// Whether the picture is advancing right now.
    public var isAdvancing: Bool {
        phase == .playing && !isPaused && !isWaitingForData
    }

    /// Whether to show a busy indicator: opening a file or stalled on the network.
    public var isBusy: Bool {
        phase == .loading || (phase == .playing && isWaitingForData && !isPaused)
    }

    /// Playback progress in `0...1`, or `nil` when the duration is unknown.
    public var progress: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }

    public mutating func apply(_ event: PlayerEvent) {
        switch event {
        case .startedLoading:
            // Volume, mute and the queue carry over; everything else is per file.
            let (volume, isMuted, playlist) = (volume, isMuted, playlist)
            self = PlaybackState()
            self.volume = volume
            self.isMuted = isMuted
            self.playlist = playlist
            phase = .loading

        case .fileLoaded:
            phase = .playing

        case .playbackRestarted:
            hasShownFirstFrame = true

        case let .ended(reason):
            switch reason {
            case .reachedEnd:
                phase = .ended
            case .stopped:
                // Replaced by another file: the next `startedLoading` takes over.
                if phase != .loading {
                    phase = .idle
                }
            case let .failed(message):
                phase = .failed(message)
            }

        case let .property(property):
            apply(property)

        case .shutdown:
            phase = .idle
        }
    }

    private mutating func apply(_ property: PlayerProperty) {
        switch property {
        case let .paused(value): isPaused = value
        case let .position(value): position = max(value ?? 0, 0)
        case let .duration(value): duration = value.flatMap { $0 > 0 ? $0 : nil }
        case let .volume(value): volume = min(max(value, 0), 100)
        case let .muted(value): isMuted = value
        case let .waitingForData(value): isWaitingForData = value
        case let .seeking(value): isSeeking = value
        case let .title(value): title = value
        case let .displayWidth(value): displayWidth = value
        case let .displayHeight(value): displayHeight = value
        case let .hardwareDecoder(value): hardwareDecoder = value
        case let .bufferedAhead(value): bufferedAhead = value
        case let .tracks(value): tracks = value
        case let .chapters(value): chapters = value
        case let .currentChapter(value): currentChapter = value
        case let .playlist(value): playlist = value
        case let .reachedEnd(value):
            if value, phase == .playing {
                phase = .ended
            } else if !value, phase == .ended {
                // Seeking back from the end resumes normal playback.
                phase = .playing
            }
        }
    }
}

public enum PlaybackTime {
    /// `m:ss`, or `h:mm:ss` from one hour up. Negative and non-finite values read as zero.
    public static func format(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        let tail = String(format: "%02d", secs)
        return hours > 0
            ? "\(hours):" + String(format: "%02d", minutes) + ":" + tail
            : "\(minutes):" + tail
    }
}
