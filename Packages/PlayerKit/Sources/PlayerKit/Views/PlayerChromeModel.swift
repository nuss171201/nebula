import Foundation
import Observation

/// Decides when the on-screen controls are visible: shown on any mouse movement,
/// hidden again after a pause in movement, but only while the picture is playing
/// and the pointer is not resting on the controls themselves.
@MainActor
@Observable
public final class PlayerChromeModel {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public private(set) var isVisible = true

    @ObservationIgnored private let hideDelay: Duration
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var isPointerOnControls = false

    public init(hideDelay: Duration = .seconds(2.5), sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.hideDelay = hideDelay
        self.sleep = sleep
    }

    /// The mouse moved over the player, or a key was pressed.
    public func userDidInteract() {
        isVisible = true
        scheduleHide()
    }

    public func pointerIsOnControls(_ isOnControls: Bool) {
        isPointerOnControls = isOnControls
        scheduleHide()
    }

    /// Tells the model whether the picture is advancing. Controls stay up while it is not.
    public func playbackChanged(isPlaying: Bool) {
        self.isPlaying = isPlaying
        if !isPlaying {
            isVisible = true
        }
        scheduleHide()
    }

    /// Waits for the pending hide timer, if any. For tests.
    func waitForPendingHide() async {
        await hideTask?.value
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = nil
        guard isVisible, isPlaying, !isPointerOnControls else { return }
        hideTask = Task { [hideDelay, sleep] in
            do {
                try await sleep(hideDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}
