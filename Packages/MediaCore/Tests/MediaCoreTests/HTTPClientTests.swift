import Foundation
@testable import MediaCore
import os
import Testing

/// A scripted transport: returns the queued outcomes in order and records what it was asked.
private final class ScriptedTransport: Sendable {
    enum Outcome: Sendable {
        case status(Int)
        case failure(URLError.Code)
        case cancellation
    }

    private struct State {
        var outcomes: [Outcome]
        var requests: [URLRequest] = []
        var sleeps: [Duration] = []
        var failSleep = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ outcomes: [Outcome], failSleep: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(outcomes: outcomes, failSleep: failSleep))
    }

    var requests: [URLRequest] { state.withLock(\.requests) }
    var sleeps: [Duration] { state.withLock(\.sleeps) }

    func client(retry: RetryPolicy) -> URLSessionHTTPClient {
        URLSessionHTTPClient(
            userAgent: "Tests/1.0",
            retryPolicy: retry,
            transport: { [self] request in
                let outcome = state.withLock { state in
                    state.requests.append(request)
                    return state.outcomes.isEmpty ? Outcome.status(200) : state.outcomes.removeFirst()
                }
                switch outcome {
                case let .status(code):
                    let url = try #require(request.url)
                    let response = try #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil))
                    return (Data("ok".utf8), response)
                case let .failure(code):
                    throw URLError(code)
                case .cancellation:
                    throw CancellationError()
                }
            },
            sleep: { [self] duration in
                let shouldFail = state.withLock { state in
                    state.sleeps.append(duration)
                    return state.failSleep
                }
                if shouldFail {
                    throw CancellationError()
                }
            }
        )
    }
}

@Suite("HTTP client reliability")
struct HTTPClientTests {
    private let request = HTTPRequest(
        url: URL(filePath: "/unused").appending(path: "x"),
        timeout: .seconds(7),
        headers: ["X-Test": "1"]
    )
    private let policy = RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(100), maxDelay: .seconds(1), jitter: 0)

    @Test("Sends the user agent, custom headers and timeout")
    func requestShape() async throws {
        let transport = ScriptedTransport([.status(200)])
        let response = try await transport.client(retry: policy).send(request)
        #expect(response.statusCode == 200)
        #expect(response.data == Data("ok".utf8))

        let sent = try #require(transport.requests.first)
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Tests/1.0")
        #expect(sent.value(forHTTPHeaderField: "X-Test") == "1")
        #expect(sent.timeoutInterval == 7)
    }

    @Test("Retries transient failures with growing delays, then succeeds")
    func retriesThenSucceeds() async throws {
        let transport = ScriptedTransport([.status(503), .failure(.timedOut), .status(200)])
        let response = try await transport.client(retry: policy).send(request)
        #expect(response.statusCode == 200)
        #expect(transport.requests.count == 3)
        #expect(transport.sleeps == [.milliseconds(100), .milliseconds(200)])
    }

    @Test("Gives up after the configured number of attempts")
    func exhaustsAttempts() async {
        let transport = ScriptedTransport([.status(500), .status(502), .status(503), .status(200)])
        await #expect(throws: HTTPError.badStatus(503)) {
            try await transport.client(retry: policy).send(request)
        }
        #expect(transport.requests.count == 3)
    }

    @Test("Does not retry errors that will not go away", arguments: [
        (ScriptedTransport.Outcome.status(404), HTTPError.badStatus(404)),
        (.status(401), .badStatus(401)),
        (.failure(.notConnectedToInternet), .offline),
        (.failure(.cancelled), .cancelled),
        (.cancellation, .cancelled),
    ])
    private func noRetry(outcome: ScriptedTransport.Outcome, expected: HTTPError) async {
        let transport = ScriptedTransport([outcome])
        await #expect(throws: expected) {
            try await transport.client(retry: policy).send(request)
        }
        #expect(transport.requests.count == 1)
        #expect(transport.sleeps.isEmpty)
    }

    @Test("Cancellation while waiting to retry stops immediately")
    func cancelledDuringBackoff() async {
        let transport = ScriptedTransport([.status(503), .status(200)], failSleep: true)
        await #expect(throws: HTTPError.cancelled) {
            try await transport.client(retry: policy).send(request)
        }
        #expect(transport.requests.count == 1)
    }

    @Test("Transport errors map to the cases the UI explains", arguments: [
        (URLError.Code.timedOut, HTTPError.timedOut),
        (.cannotFindHost, .cannotReachServer),
        (.cannotConnectToHost, .cannotReachServer),
        (.networkConnectionLost, .cannotReachServer),
        (.dataNotAllowed, .offline),
    ])
    func errorMapping(code: URLError.Code, expected: HTTPError) async {
        let transport = ScriptedTransport([.failure(code)])
        await #expect(throws: expected) {
            try await transport.client(retry: .none).send(request)
        }
    }

    @Test("Retryable errors are exactly the transient ones")
    func retryability() {
        #expect(HTTPError.timedOut.isRetryable)
        #expect(HTTPError.cannotReachServer.isRetryable)
        #expect(HTTPError.badStatus(429).isRetryable)
        #expect(HTTPError.badStatus(500).isRetryable)
        #expect(!HTTPError.badStatus(404).isRetryable)
        #expect(!HTTPError.offline.isRetryable)
        #expect(!HTTPError.cancelled.isRetryable)
        #expect(!HTTPError.invalidResponse.isRetryable)
    }
}
