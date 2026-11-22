import Foundation

/// A page that was opened to play (`AppModel.play`).
public extension AppModel {
    /// How long after the first playable stream has arrived Play is pressed, if other add-ons
    /// have still to answer: long enough for the usual ones, short enough not to feel like a wait.
    static let settleTime = Duration.milliseconds(1500)
    /// When to stop waiting for a page that never gets anything to play.
    static let playPatience = Duration.seconds(60)

    /// Presses Play on a page that was opened to play, once it has streams to choose from.
    /// Returns whether it did. Does nothing for a page opened any other way, and only once.
    ///
    /// Not at the first stream to arrive: the best one may come from an add-on that answers a
    /// moment later. Not after the last add-on either: one that never answers would hold up
    /// the rest for its whole timeout.
    @discardableResult
    func playWhenReady(_ detail: DetailModel) async -> Bool {
        await playWhenReady(detail, pollingEvery: .milliseconds(100)) { [weak self] in self?.playBestStream(of: $0) }
    }

    /// - Parameter press: What "pressing Play" is. Tests count the presses instead of opening a player.
    @discardableResult
    internal func playWhenReady(_ detail: DetailModel, pollingEvery interval: Duration, press: @MainActor (DetailModel) -> Void) async -> Bool {
        guard detail.startsPlaying else { return false }
        detail.startsPlaying = false
        let started = ContinuousClock.now
        var firstPickAt: ContinuousClock.Instant?
        while !Task.isCancelled, ContinuousClock.now - started < Self.playPatience {
            let streams = detail.streams
            if !streams.picks.isEmpty {
                let since = firstPickAt ?? .now
                firstPickAt = since
                if streams.phase == .finished || ContinuousClock.now - since >= Self.settleTime {
                    press(detail)
                    return true
                }
            } else if Self.hasNothingToPlay(detail) {
                return false
            }
            try? await Task.sleep(for: interval)
        }
        return false
    }

    /// The page has finished looking and there is nothing Play could start: it failed to load,
    /// its streams are all in and none can be played, or it is a series with no episode to start on.
    private static func hasNothingToPlay(_ detail: DetailModel) -> Bool {
        switch detail.phase {
        case .loading: false
        case .failed: true
        case .loaded: detail.streams.phase != .loading
        }
    }
}
