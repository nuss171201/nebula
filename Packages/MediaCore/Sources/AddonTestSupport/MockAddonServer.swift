import Foundation
import Network
import os

/// A tiny HTTP/1.1 server on 127.0.0.1 that plays the part of an add-on in tests.
///
/// Routes are exact request targets (path plus query, still percent-encoded), so a
/// test also verifies that the client builds URLs the way the protocol specifies.
public final class MockAddonServer: Sendable {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public var contentType: String
        /// How long to wait before answering, to simulate a slow server.
        public var delay: Duration

        public init(status: Int = 200, body: Data = Data(), contentType: String = "application/json", delay: Duration = .zero) {
            self.status = status
            self.body = body
            self.contentType = contentType
            self.delay = delay
        }

        public static func json(_ text: String, status: Int = 200, delay: Duration = .zero) -> Response {
            Response(status: status, body: Data(text.utf8), delay: delay)
        }

        public static func status(_ code: Int) -> Response {
            Response(status: code, body: Data("error".utf8), contentType: "text/plain")
        }
    }

    public enum ServerError: Error {
        case notStarted
        case failedToStart(String)
    }

    private struct State {
        var routes: [String: [Response]] = [:]
        var requests: [String] = []
        var didResumeStart = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MockAddonServer")

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    deinit {
        listener.cancel()
    }

    /// Starts listening and returns the server's base URL, for example `http://127.0.0.1:51234/`.
    public func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: queue)
            receive(on: connection, buffer: Data())
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [state] newState in
                let outcome: Result<Void, any Error>? = switch newState {
                case .ready: .success(())
                case let .failed(error): .failure(ServerError.failedToStart(error.localizedDescription))
                case .cancelled: .failure(ServerError.failedToStart("cancelled"))
                default: nil
                }
                guard let outcome else { return }
                let isFirst = state.withLock { state in
                    defer { state.didResumeStart = true }
                    return !state.didResumeStart
                }
                if isFirst {
                    continuation.resume(with: outcome)
                }
            }
            listener.start(queue: queue)
        }

        guard let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
            throw ServerError.notStarted
        }
        return url
    }

    public func stop() {
        listener.cancel()
    }

    /// Sets the responses for a request target such as `/catalog/movie/top.json`.
    /// With several responses, each is used once in order and the last one repeats.
    public func respond(to target: String, with responses: Response...) {
        state.withLock { $0.routes[target] = responses }
    }

    /// Every request target received so far, in order.
    public var requestedTargets: [String] {
        state.withLock(\.requests)
    }

    public func requestCount(for target: String) -> Int {
        requestedTargets.count { $0 == target }
    }

    // MARK: - Connection handling

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let terminator = buffer.range(of: Self.headerTerminator) {
                answer(connection, head: buffer[..<terminator.lowerBound])
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    private func answer(_ connection: NWConnection, head: Data) {
        let requestLine = String(bytes: head, encoding: .utf8)?
            .split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        let target = parts.count >= 2 ? String(parts[1]) : ""

        let response: Response = state.withLock { state in
            state.requests.append(target)
            guard var queued = state.routes[target], let next = queued.first else {
                return .status(404)
            }
            if queued.count > 1 {
                queued.removeFirst()
                state.routes[target] = queued
            }
            return next
        }

        let send: @Sendable () -> Void = { [queue] in
            var message = Data("""
            HTTP/1.1 \(response.status) \(Self.reason(for: response.status))\r
            Content-Type: \(response.contentType)\r
            Content-Length: \(response.body.count)\r
            Connection: close\r
            \r

            """.utf8)
            message.append(response.body)
            connection.send(content: message, completion: .contentProcessed { _ in
                queue.async { connection.cancel() }
            })
        }

        if response.delay > .zero {
            let seconds = Double(response.delay.components.seconds) + Double(response.delay.components.attoseconds) / 1e18
            queue.asyncAfter(deadline: .now() + seconds, execute: send)
        } else {
            send()
        }
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 404: "Not Found"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
