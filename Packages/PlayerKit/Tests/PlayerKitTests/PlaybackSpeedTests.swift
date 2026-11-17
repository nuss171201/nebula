@testable import PlayerKit
import Testing

@Suite("Playback speed")
struct PlaybackSpeedTests {
    @Test("Values are clamped into 0.25×–16×", arguments: [
        (1.0, 1.0),
        (0.1, 0.25),
        (0.25, 0.25),
        (16.0, 16.0),
        (40.0, 16.0),
        (0.0, 1.0),
        (-2.0, 1.0),
        (Double.nan, 1.0),
        (Double.infinity, 1.0),
    ])
    func clamping(input: Double, expected: Double) {
        #expect(PlaybackSpeed(input).value == expected)
    }

    @Test("Stepping up walks the presets and stops at the maximum")
    func stepUp() {
        #expect(PlaybackSpeed(1).steppedUp().value == 1.25)
        #expect(PlaybackSpeed(1.1).steppedUp().value == 1.25)
        #expect(PlaybackSpeed(2).steppedUp().value == 3)
        #expect(PlaybackSpeed(16).steppedUp().value == 16)
    }

    @Test("Stepping down walks the presets and stops at the minimum")
    func stepDown() {
        #expect(PlaybackSpeed(1).steppedDown().value == 0.75)
        #expect(PlaybackSpeed(1.1).steppedDown().value == 1)
        #expect(PlaybackSpeed(0.25).steppedDown().value == 0.25)
    }

    @Test("Walking up from the minimum visits every preset exactly once")
    func fullLadder() {
        var speed = PlaybackSpeed(PlaybackSpeed.range.lowerBound)
        var visited = [speed.value]
        while speed.steppedUp() != speed {
            speed = speed.steppedUp()
            visited.append(speed.value)
        }
        #expect(visited == PlaybackSpeed.presets)
    }

    @Test("Labels drop a trailing .0", arguments: [
        (1.0, "1×"),
        (1.25, "1.25×"),
        (0.5, "0.5×"),
        (16.0, "16×"),
    ])
    func labels(input: Double, expected: String) {
        #expect(PlaybackSpeed(input).label == expected)
    }
}
