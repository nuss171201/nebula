/// A playback rate, always inside the supported 0.25×–16× window.
public struct PlaybackSpeed: Hashable, Sendable, Comparable {
    public static let range: ClosedRange<Double> = 0.25 ... 16
    public static let normal = PlaybackSpeed(1)

    /// The stops used by the "faster" / "slower" commands, ascending.
    public static let presets: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4, 8, 16]

    public let value: Double

    /// Clamps into `range`. A non-finite or non-positive value becomes normal speed.
    public init(_ value: Double) {
        guard value.isFinite, value > 0 else {
            self.value = 1
            return
        }
        self.value = min(max(value, Self.range.lowerBound), Self.range.upperBound)
    }

    /// The next preset above the current speed, or the maximum if already there.
    public func steppedUp() -> PlaybackSpeed {
        let next = Self.presets.first { $0 > value + Self.tolerance }
        return PlaybackSpeed(next ?? Self.range.upperBound)
    }

    /// The next preset below the current speed, or the minimum if already there.
    public func steppedDown() -> PlaybackSpeed {
        let previous = Self.presets.last { $0 < value - Self.tolerance }
        return PlaybackSpeed(previous ?? Self.range.lowerBound)
    }

    /// Short label for menus and the on-screen display, for example `1×` or `1.25×`.
    public var label: String {
        let rounded = (value * 100).rounded() / 100
        let text = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(rounded)
        return text + "×"
    }

    public static func < (lhs: PlaybackSpeed, rhs: PlaybackSpeed) -> Bool {
        lhs.value < rhs.value
    }

    private static let tolerance = 0.000_1
}
