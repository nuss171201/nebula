import Foundation
import PlayerKit

/// Play, choosing for the user: the most suitable stream first, and the next if it will not start.
extension StreamPlayer {
    enum StartOutcome {
        case started, failed, timedOut
        /// The user closed the player or pressed Cancel: stop, do not try something else.
        case abandoned
    }

    /// Plays the first of `candidates` that starts: each gets a while to show its first
    /// picture, and if it fails, or nothing of it arrives, the next is tried, up to three in all.
    /// - Parameters:
    ///   - candidates: Most suitable first, as the picker ordered them.
    ///   - onStarted: Called with the stream that ended up playing.
    public func playAutomatically(
        _ candidates: [StreamChoice],
        for video: StreamVideo,
        onStarted: @escaping @MainActor (StreamChoice) -> Void = { _ in }
    ) {
        cancel()
        let attempts = Array(candidates.prefix(Self.automaticAttempts))
        guard !attempts.isEmpty else {
            phase = .failed(title: video.title, message: "Nothing here can be played by itself. Choose a stream from the list.")
            return
        }
        automaticTask = Task { [weak self] in
            for (index, choice) in attempts.enumerated() {
                guard let self, !Task.isCancelled else { return }
                arrivalSigns = ArrivalSigns()
                start(choice, for: video)
                let outcome = await waitForStart(of: choice, othersToTry: index + 1 < attempts.count)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .started:
                    onStarted(choice)
                    return
                case .abandoned:
                    return
                case .failed, .timedOut:
                    abandonAttempt()
                    if index + 1 < attempts.count {
                        let detail = "That stream did not start. Trying another (\(index + 2) of \(attempts.count))…"
                        phase = .preparing(title: video.title, detail: detail)
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            let message = attempts.count == 1
                ? "The stream that was tried would not start. Choose one from the list."
                : "None of the \(attempts.count) streams tried would start. Choose one from the list."
            phase = .failed(title: video.title, message: message)
        }
    }

    /// Watches one attempt until its first picture, its failure, or the end of Play's patience with it.
    private func waitForStart(of choice: StreamChoice, othersToTry: Bool) async -> StartOutcome {
        let patience = choice.kind == .torrent ? patience.torrent : patience.direct
        let started = ContinuousClock.now
        var playerWasOpen = false
        while true {
            let now = ContinuousClock.now
            let isUp = patience.isUp(
                waited: now - started,
                sinceArrival: arrivalSigns.lastArrival.map { now - $0 },
                secondsLeft: arrivalSigns.secondsLeft,
                othersToTry: othersToTry
            )
            if isUp {
                return .timedOut
            }
            if Task.isCancelled {
                return .abandoned
            }
            if case .failed = phase {
                return .failed
            }
            if coordinator.errorMessage != nil {
                coordinator.errorMessage = nil
                return .failed
            }
            if let player = coordinator.player, coordinator.isPlayerOpen {
                playerWasOpen = true
                // Only what the player says about this attempt counts, not what it still shows of the last.
                guard isPlaying(choice, in: player) else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                let state = player.state
                if case .failed = state.phase {
                    return .failed
                }
                if state.phase == .ended || (state.phase == .playing && (state.hasShownFirstFrame || state.isAudioOnly)) {
                    return .started
                }
            } else if playerWasOpen {
                return .abandoned
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func isPlaying(_ choice: StreamChoice, in player: PlayerModel) -> Bool {
        guard let playing = player.source?.url else { return false }
        switch choice.stream.source {
        case let .url(url): return playing == url
        case .torrent: return activeURL != nil && playing == activeURL
        case .youTube, .external: return false
        }
    }

    /// Clears away an attempt that did not start, so the next one begins from nothing.
    private func abandonAttempt() {
        prepareTask?.cancel()
        prepareTask = nil
        closeActiveTorrent()
        if coordinator.isPlayerOpen {
            coordinator.closePlayer()
        }
        nowPlaying = nil
        nowPlayingChoice = nil
        phase = .idle
    }
}
