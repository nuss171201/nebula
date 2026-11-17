import AppKit

/// Keys, scrolling, pinching and the system's media keys.
extension PlayerWindowController {
    /// Connects the window's key, scroll and pinch events, and the system's Now Playing
    /// display if there is one, to the player.
    func connectInput(nowPlaying center: (any NowPlayingCenter)?) {
        window.onKeyDown = { [weak self] chord in
            self?.handle(chord) ?? false
        }
        window.onScroll = { [weak self] event in
            // Momentum after the fingers have lifted would overshoot what was asked for.
            guard event.momentumPhase.isEmpty else { return }
            // Directions as the fingers moved, whatever the system's scroll direction is set to.
            let inverted = event.isDirectionInvertedFromDevice
            self?.scrolled(
                right: inverted ? event.scrollingDeltaX : -event.scrollingDeltaX,
                up: inverted ? -event.scrollingDeltaY : event.scrollingDeltaY,
                isPrecise: event.hasPreciseScrollingDeltas,
                began: event.phase.contains(.began)
            )
        }
        window.onMagnify = { [weak self] event in
            self?.pinched(by: event.magnification, began: event.phase.contains(.began))
        }
        if let center {
            nowPlaying = NowPlayingSession(model: model, center: center) { [weak self] command in
                self?.perform(command)
            }
        }
    }

    /// Acts on a key press as if it had been typed in the player window. Returns whether a
    /// binding matched and its command was handled.
    @discardableResult
    public func press(_ chord: KeyChord) -> Bool {
        handle(chord)
    }

    /// Scrolling over the player: volume up and down, seeking left and right.
    func scrolled(right: Double, up: Double, isPrecise: Bool, began: Bool) {
        if began {
            scrolling.begin()
        }
        if let command = scrolling.scroll(right: right, up: up, isPrecise: isPrecise) {
            chrome.userDidInteract()
            perform(command)
        }
    }

    /// Pinching the player: spread to enter full screen, pinch to leave it.
    func pinched(by amount: Double, began: Bool) {
        if began {
            pinching.begin()
        }
        switch pinching.magnify(by: amount) {
        case .enterFullScreen where !isFullScreen:
            perform(.toggleFullScreen)
        case .exitFullScreen where isFullScreen:
            toggleFullScreen()
        default:
            break
        }
    }

    func handle(_ chord: KeyChord) -> Bool {
        guard let command = bindings.command(for: chord) else { return false }
        chrome.userDidInteract()
        return perform(command)
    }
}
