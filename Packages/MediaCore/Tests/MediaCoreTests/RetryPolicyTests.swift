@testable import MediaCore
import Testing

@Suite("Retry backoff schedule")
struct RetryPolicyTests {
    private let policy = RetryPolicy(
        maxAttempts: 5,
        baseDelay: .milliseconds(500),
        maxDelay: .seconds(3),
        multiplier: 2,
        jitter: 0.2
    )

    @Test("Delays double each retry and stop at the cap (jitter centred)")
    func exponentialGrowth() {
        #expect(policy.delay(beforeRetry: 1, randomUnit: 0.5) == .milliseconds(500))
        #expect(policy.delay(beforeRetry: 2, randomUnit: 0.5) == .seconds(1))
        #expect(policy.delay(beforeRetry: 3, randomUnit: 0.5) == .seconds(2))
        #expect(policy.delay(beforeRetry: 4, randomUnit: 0.5) == .seconds(3))
    }

    @Test("Returns nil when attempts are used up or the retry index is invalid")
    func exhaustion() {
        #expect(policy.delay(beforeRetry: 5, randomUnit: 0.5) == nil)
        #expect(policy.delay(beforeRetry: 0, randomUnit: 0.5) == nil)
        #expect(RetryPolicy.none.delay(beforeRetry: 1) == nil)
    }

    @Test("Jitter stays inside its window and never exceeds the cap")
    func jitterBounds() throws {
        let low = try #require(policy.delay(beforeRetry: 1, randomUnit: 0))
        let high = try #require(policy.delay(beforeRetry: 1, randomUnit: 1))
        #expect(low == .milliseconds(400))
        #expect(high == .milliseconds(600))

        let capped = try #require(policy.delay(beforeRetry: 4, randomUnit: 1))
        #expect(capped == .seconds(3))
    }

    @Test("Initialiser clamps nonsensical values")
    func clamping() {
        let odd = RetryPolicy(maxAttempts: 0, baseDelay: .seconds(1), maxDelay: .seconds(1), multiplier: 0.1, jitter: 7)
        #expect(odd.maxAttempts == 1)
        #expect(odd.multiplier == 1)
        #expect(odd.jitter == 1)
    }
}
