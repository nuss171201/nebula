import Foundation
import MediaCore
import os

/// An `HTTPClient` whose responses come from a closure, for tests that should not open sockets.
public final class StubHTTPClient: HTTPClient {
    public typealias Handler = @Sendable (HTTPRequest) async throws(HTTPError) -> HTTPResponse

    private let handler: Handler
    private let recorded = OSAllocatedUnfairLock(initialState: [URL]())

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Answers every request with the same body.
    public convenience init(data: Data) {
        self.init { _ in HTTPResponse(data: data, statusCode: 200) }
    }

    /// Every URL requested so far, in order.
    public var requestedURLs: [URL] {
        recorded.withLock { $0 }
    }

    public func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        recorded.withLock { $0.append(request.url) }
        return try await handler(request)
    }
}
