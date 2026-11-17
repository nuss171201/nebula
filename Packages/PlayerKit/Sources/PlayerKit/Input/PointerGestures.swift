import Foundation

/// Turns scrolling over the player into commands: up and down change the volume, left and
/// right seek. One gesture does one of the two, decided by how it starts.
///
/// Directions here are the fingers' (or the wheel's) own: `up` is positive when the fingers
/// move up, whatever the system's scroll direction setting.
struct ScrollInterpreter {
    private enum Axis {
        case horizontal, vertical
    }

    /// Points of trackpad travel for one point of volume.
    static let pointsPerVolumePoint = 4.0
    /// Points of trackpad travel for one second of seeking.
    static let pointsPerSecond = 6.0
    /// What one click of a mouse wheel does.
    static let wheelVolumeStep = 2.0
    static let wheelSeekStep = 5.0

    private var axis: Axis?
    private var travelled = 0.0

    /// A new gesture starts: forget the previous one's direction and remainder.
    mutating func begin() {
        axis = nil
        travelled = 0
    }

    /// - Parameter isPrecise: `true` for a trackpad (movement in points), `false` for a wheel (in clicks).
    mutating func scroll(right: Double, up: Double, isPrecise: Bool) -> PlayerCommand? {
        guard isPrecise else {
            // A wheel has no gesture to lock: each click stands alone.
            if abs(up) >= abs(right), up != 0 {
                return .changeVolumeBy(up > 0 ? Self.wheelVolumeStep : -Self.wheelVolumeStep)
            }
            return right == 0 ? nil : .seekBy(right > 0 ? Self.wheelSeekStep : -Self.wheelSeekStep)
        }
        if axis == nil {
            guard max(abs(right), abs(up)) >= 0.5 else { return nil }
            axis = abs(right) > abs(up) ? .horizontal : .vertical
        }
        switch axis {
        case .vertical:
            travelled += up
            let points = (travelled / Self.pointsPerVolumePoint).rounded(.towardZero)
            guard points != 0 else { return nil }
            travelled -= points * Self.pointsPerVolumePoint
            return .changeVolumeBy(points)
        case .horizontal:
            travelled += right
            let seconds = (travelled / Self.pointsPerSecond).rounded(.towardZero)
            guard seconds != 0 else { return nil }
            travelled -= seconds * Self.pointsPerSecond
            return .seekBy(seconds)
        case nil:
            return nil
        }
    }
}

/// Turns a pinch into entering or leaving full screen: spreading the fingers enters it,
/// pinching them together leaves it, once the pinch is clearly meant.
struct PinchInterpreter {
    enum Outcome: Equatable {
        case enterFullScreen, exitFullScreen
    }

    static let threshold = 0.25

    private var total = 0.0
    private var hasFired = false

    mutating func begin() {
        total = 0
        hasFired = false
    }

    /// At most one outcome per pinch.
    mutating func magnify(by amount: Double) -> Outcome? {
        guard !hasFired else { return nil }
        total += amount
        guard abs(total) >= Self.threshold else { return nil }
        hasFired = true
        return total > 0 ? .enterFullScreen : .exitFullScreen
    }
}
