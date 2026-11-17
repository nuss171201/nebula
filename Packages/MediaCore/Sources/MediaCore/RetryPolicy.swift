/// Exponential backoff with jitter for network calls.
///
/// Pure value type: it only computes delays, so the schedule is unit-testable
/// without sleeping. The HTTP client owns the actual waiting and cancellation.
public struct RetryPolicy: Sendable, Equatable {
    /// Total number of attempts, including the first one. `1` disables retrying.
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    public var multiplier: Double
    /// Fraction of the delay that is randomised, in `0...1`. `0.2` means ±20 %.
    public var jitter: Double

    public init(maxAttempts: Int, baseDelay: Duration, maxDelay: Duration, multiplier: Double = 2, jitter: Double = 0.2) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.multiplier = max(1, multiplier)
        self.jitter = min(max(jitter, 0), 1)
    }

    public static let standard = RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(400), maxDelay: .seconds(8))
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero)

    /// How long to wait before retry number `retry` (1 = the first retry).
    /// Returns `nil` once the attempts are used up.
    ///
    /// - Parameter randomUnit: A value in `0...1` that positions the delay inside the
    ///   jitter window. Injected so tests are deterministic.
    public func delay(beforeRetry retry: Int, randomUnit: Double = .random(in: 0 ... 1)) -> Duration? {
        guard retry >= 1, retry < maxAttempts else { return nil }

        var seconds = baseDelay.seconds
        for _ in 1 ..< retry {
            seconds *= multiplier
            if seconds >= maxDelay.seconds {
                break
            }
        }
        let unit = min(max(randomUnit, 0), 1)
        let jittered = seconds * (1 + jitter * (2 * unit - 1))
        return .seconds(min(max(jittered, 0), maxDelay.seconds))
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
