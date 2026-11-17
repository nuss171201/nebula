import Foundation

/// A short message flashed over the picture after a command whose effect cannot otherwise be
/// seen, such as a key press that changes the speed while the controls are hidden.
public struct PlayerNotice: Sendable, Equatable, Identifiable {
    public let id: Int
    public let text: String
}

/// What will play when the current video is over, offered with a countdown. The player only
/// shows it; whoever made the offer counts down, and acts on the answer.
public struct UpNextOffer: Sendable, Equatable {
    /// What is next: "S1 · E3 — The Title".
    public var title: String
    /// A second line, such as the series' name.
    public var detail: String?
    /// Seconds until it starts by itself.
    public var secondsRemaining: Int

    public init(title: String, detail: String? = nil, secondsRemaining: Int) {
        self.title = title
        self.detail = detail
        self.secondsRemaining = max(secondsRemaining, 0)
    }
}

/// Commands from keys, menus and gestures, and the notices that confirm them.
extension PlayerModel {
    /// Runs a command that only concerns playback. Window commands return `false`
    /// so the caller (the window) can handle them.
    @discardableResult
    public func perform(_ command: PlayerCommand) -> Bool {
        switch command {
        case .togglePause: togglePause()
        case let .setPaused(isPaused): setPaused(isPaused)
        case let .seekTo(seconds): seek(to: seconds)
        case let .seekBy(seconds): seek(by: seconds)
        case let .changeVolumeBy(amount): changeVolume(by: amount)
        case .toggleMute: toggleMuteWithNotice()
        case .stepFrameForward: stepFrameForward()
        case .stepFrameBackward: stepFrameBackward()
        case .speedUp: changeSpeed(to: speed.steppedUp())
        case .slowDown: changeSpeed(to: speed.steppedDown())
        case .resetSpeed: changeSpeed(to: .normal)
        case .nextChapter: stepChapter(by: 1)
        case .previousChapter: stepChapter(by: -1)
        case .playNext: playNext()
        case .playPrevious: playPrevious()
        case .cycleABLoop: cycleABLoopWithNotice()
        case .toggleSubtitles: toggleSubtitlesWithNotice()
        case let .shiftAudioDelay(seconds): shiftAudioDelay(by: seconds)
        case let .shiftSubtitleDelay(seconds): shiftSubtitleDelay(by: seconds)
        case let .cycleTrack(kind): cycleTrack(kind)
        case let .screenshot(includingSubtitles):
            Task { await saveScreenshot(includingSubtitles: includingSubtitles) }
        default: return false
        }
        return true
    }

    /// Shows a message over the picture. A newer message replaces an older one.
    func announce(_ text: String) {
        noticeCount += 1
        notice = PlayerNotice(id: noticeCount, text: text)
    }

    /// Takes a message down again, unless a newer one has replaced it in the meantime.
    public func dismissNotice(_ id: Int) {
        if notice?.id == id {
            notice = nil
        }
    }

    // MARK: - Commands with a notice

    private func changeVolume(by amount: Double) {
        setVolume(state.volume + amount)
        announce("Volume \(Int(state.volume.rounded())) %")
    }

    private func toggleMuteWithNotice() {
        toggleMute()
        announce(state.isMuted ? "Muted" : "Sound On")
    }

    private func changeSpeed(to newSpeed: PlaybackSpeed) {
        speed = newSpeed
        announce("Speed \(speed.label)")
    }

    private func stepChapter(by offset: Int) {
        guard !state.chapters.isEmpty else {
            announce("No Chapters")
            return
        }
        if offset > 0 {
            nextChapter()
        } else {
            previousChapter()
        }
        let target = (state.currentChapter ?? -1) + offset
        if state.chapters.indices.contains(target) {
            announce(state.chapters[target].title)
        }
    }

    private func cycleABLoopWithNotice() {
        cycleABLoop()
        switch abLoop {
        case .off:
            announce("Loop Off")
        case let .startMarked(start):
            announce("Loop Start \(PlaybackTime.format(start))")
        case let .looping(start, end):
            announce("Looping \(PlaybackTime.format(start)) – \(PlaybackTime.format(end))")
        }
    }

    private func toggleSubtitlesWithNotice() {
        subtitles.isVisible.toggle()
        announce(subtitles.isVisible ? "Subtitles On" : "Subtitles Hidden")
    }

    private func shiftAudioDelay(by seconds: Double) {
        audio.delay = ((audio.delay + seconds) * 1000).rounded() / 1000
        announce("Audio Delay \(formattedDelay(audio.delay))")
    }

    private func shiftSubtitleDelay(by seconds: Double) {
        subtitles.delay = ((subtitles.delay + seconds) * 1000).rounded() / 1000
        announce("Subtitle Delay \(formattedDelay(subtitles.delay))")
    }
}
