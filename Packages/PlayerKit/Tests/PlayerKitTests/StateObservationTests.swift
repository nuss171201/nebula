import Foundation
import Observation
@testable import PlayerKit
import Testing

@MainActor
@Suite("Who is told when the player's state changes")
struct StateObservationTests {
    private func makePlayer() throws -> PlayerModel {
        try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .none,
            playsAudio: false
        ))
    }

    /// Whether `change` invalidates something that has read `read`.
    private func invalidates(_ read: @MainActor () -> Void, when change: @MainActor () -> Void) -> Bool {
        let fired = Flag()
        withObservationTracking(read) {
            fired.set()
        }
        change()
        return fired.isSet
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() {
            lock.withLock { value = true }
        }
    }

    @Test("The playhead moving is news for whoever follows the playhead, and for nobody else")
    func playhead() throws {
        let player = try makePlayer()
        defer { player.shutdown() }

        let told1 = invalidates {
            _ = player.state.phase
        } when: {
            player.state.apply(.property(.position(12)))
        }
        #expect(!told1)
        #expect(player.state.position == 12)
        let told2 = invalidates {
            _ = player.state.tracks
        } when: {
            player.state.apply(.property(.bufferedAhead(30)))
        }
        #expect(!told2)
        #expect(player.state.bufferedAhead == 30)

        let told3 = invalidates {
            _ = player.playhead
        } when: {
            player.state.apply(.property(.position(13)))
        }
        #expect(told3)
        let told4 = invalidates {
            _ = player.displayPosition
        } when: {
            player.state.apply(.property(.position(14)))
        }
        #expect(told4)
        #expect(player.playhead == 14)
        #expect(player.displayPosition == 14)
    }

    @Test("Everything else is news for whoever reads the state, and a write that changes nothing is not news")
    func state() throws {
        let player = try makePlayer()
        defer { player.shutdown() }

        let told5 = invalidates {
            _ = player.state.isPaused
        } when: {
            player.state.apply(.property(.paused(true)))
        }
        #expect(told5)
        let told6 = invalidates {
            _ = player.state.phase
        } when: {
            player.state.apply(.property(.duration(90)))
        }
        #expect(told6)
        // Both at once: both are told.
        let told7 = invalidates {
            _ = player.playhead
        } when: {
            var next = player.state
            next.position = 40
            next.isMuted = true
            player.state = next
        }
        #expect(told7)
        let told8 = invalidates {
            _ = player.state.isMuted
        } when: {
            var next = player.state
            next.position = 41
            next.isMuted = false
            player.state = next
        }
        #expect(told8)
        // The followers of the playhead are left alone by changes elsewhere.
        let told9 = invalidates {
            _ = player.playhead
        } when: {
            player.state.apply(.property(.muted(true)))
        }
        #expect(!told9)

        let told10 = invalidates {
            _ = player.state.isPaused
        } when: {
            player.state.apply(.property(.paused(true)))
        }
        #expect(!told10)
        let told11 = invalidates {
            _ = player.playhead
        } when: {
            player.state.apply(.property(.position(41)))
        }
        #expect(!told11)
    }
}
