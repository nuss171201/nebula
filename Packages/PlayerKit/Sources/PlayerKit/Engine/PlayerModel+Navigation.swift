import CoreGraphics
import Foundation

/// Moving around: chapters, the queue, single frames, A-B loops, and capturing the current frame.
public extension PlayerModel {
    func seek(toChapter index: Int) {
        guard state.chapters.indices.contains(index) else { return }
        client.set("chapter", to: .int(Int64(index)))
    }

    func nextChapter() {
        client.command(["add", "chapter", "1"])
    }

    func previousChapter() {
        client.command(["add", "chapter", "-1"])
    }

    /// Replaces the queue with these sources, in this order, and starts playing the one at `index`.
    func open(_ sources: [PlayableSource], startingAt index: Int = 0) {
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
    func enqueue(_ source: PlayableSource) {
        client.command(["loadfile", source.engineArgument, state.hasMedia || state.phase == .loading ? "append" : "append-play"])
    }

    func playNext() {
        client.command(["playlist-next", "weak"])
    }

    func playPrevious() {
        client.command(["playlist-prev", "weak"])
    }

    func play(queueIndex index: Int) {
        guard state.playlist.indices.contains(index) else { return }
        client.command(["playlist-play-index", String(index)])
    }

    /// Takes an entry out of the queue. Removing the one that is playing moves on to the next.
    func removeFromQueue(at index: Int) {
        guard state.playlist.indices.contains(index) else { return }
        client.command(["playlist-remove", String(index)])
    }

    /// Moves an entry so that it comes just before the entry now at `destination`
    /// (`destination == count` moves it to the end). Playback is not interrupted.
    func moveQueueEntry(from index: Int, toBefore destination: Int) {
        guard state.playlist.indices.contains(index), (0 ... state.playlist.count).contains(destination) else { return }
        client.command(["playlist-move", String(index), String(destination)])
    }

    /// Advances one frame and pauses.
    func stepFrameForward() {
        client.command(["frame-step"])
    }

    /// Goes back one frame and pauses.
    func stepFrameBackward() {
        client.command(["frame-back-step"])
    }

    /// Marks the loop start, then the loop end, then clears the loop.
    func cycleABLoop() {
        setABLoop(abLoop.advanced(at: state.position))
    }

    func setABLoop(_ loop: ABLoop) {
        abLoop = loop
        for write in loop.engineWrites {
            client.set(write.name, to: write.value)
        }
    }

    /// The current frame at the video's own resolution, with or without subtitles.
    func captureFrame(includingSubtitles: Bool) async -> CGImage? {
        guard state.hasMedia else { return nil }
        let client = client
        let mode = includingSubtitles ? "subtitles" : "video"
        let node = await Task.detached(priority: .userInitiated) {
            client.commandResult(["screenshot-raw", mode])
        }.value
        return node.flatMap(FrameImage.make(from:))
    }

    /// Saves the current frame as a PNG in the screenshot folder and says so on screen.
    /// Returns where it was written, or `nil` if there was no picture or it could not be saved.
    @discardableResult
    func saveScreenshot(includingSubtitles: Bool) async -> URL? {
        let position = state.position
        let fileName = source?.isLocalFile == true ? source?.displayName : nil
        let baseName = ScreenshotFile.baseName(title: title, isFileName: title == fileName, position: position)
        guard let image = await captureFrame(includingSubtitles: includingSubtitles) else {
            announce("Nothing to Capture")
            return nil
        }
        let directory = screenshotDirectory
        do {
            let url = try await Task.detached(priority: .utility) {
                try ScreenshotFile.write(image, baseName: baseName, in: directory)
            }.value
            announce("Screenshot Saved")
            return url
        } catch {
            logger.error("screenshot not saved: \(error.localizedDescription, privacy: .public)")
            announce("Could Not Save the Screenshot")
            return nil
        }
    }
}
