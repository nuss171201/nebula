import CoreGraphics
import Foundation

/// Still frames for the seek bar's hover preview, and how much of the file is buffered.
public extension PlayerModel {
    /// How many seconds one preview stands for: the file is divided into at most 150 steps,
    /// never finer than one second.
    internal nonisolated static func thumbnailStep(duration: Double) -> Double {
        max(duration / 150, 1)
    }

    /// The fraction of the file that is buffered, from the start: the playhead plus what is read ahead.
    var bufferedFraction: Double? {
        guard let duration = state.duration, duration > 0, let ahead = state.bufferedAhead else { return nil }
        return min(max((state.position + ahead) / duration, 0), 1)
    }

    /// Whether still frames can be asked for yet: a file is open, it has a picture and its
    /// length is known. These arrive one after another while a file opens, so a preview asked
    /// for too early must be asked for again when this turns true.
    var canPreviewFrames: Bool {
        state.hasMedia && state.videoSize != nil && (state.duration ?? 0) > 0 && source != nil
    }

    /// A small still frame near `seconds`, for the seek bar's hover preview. `nil` when
    /// `canPreviewFrames` is false or a newer request has overtaken this one.
    func thumbnail(at seconds: Double) async -> CGImage? {
        guard canPreviewFrames, let source, let duration = state.duration else { return nil }
        let step = Self.thumbnailStep(duration: duration)
        let bucket = Int(max(seconds, 0) / step)
        if let cached = thumbnailCache[bucket] {
            return cached
        }
        let generator = thumbnailGenerator ?? ThumbnailGenerator(source: source, userAgent: userAgent)
        thumbnailGenerator = generator
        let image = await generator.thumbnail(at: Double(bucket) * step)
        // The file may have changed while the frame was being made.
        guard let image, thumbnailGenerator === generator else { return nil }
        thumbnailCache[bucket] = image
        return image
    }

    internal func discardThumbnails() {
        thumbnailGenerator?.shutDown()
        thumbnailGenerator = nil
        thumbnailCache = [:]
    }
}
