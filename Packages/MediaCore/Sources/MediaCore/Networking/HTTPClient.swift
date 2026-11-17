import Foundation

/// A GET request with the reliability rules every network call in the app follows:
/// a timeout, cancellation, and retry with backoff.
public struct HTTPRequest: Sendable, Hashable {
    public var url: URL
    /// Maximum time to wait for the server to respond or send more data.
    public var timeout: Duration
    public var headers: [String: String]

    public init(url: URL, timeout: Duration = .seconds(15), headers: [String: String] = [:]) {
        self.url = url
        self.timeout = timeout
        self.headers = headers
    }
}

public struct HTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

/// Why a request failed, reduced to the cases the UI can explain.
public enum HTTPError: Error, Sendable, Equatable {
    case cancelled
    case timedOut
    case offline
    case cannotReachServer
    case badStatus(Int)
    case invalidResponse
    case other(String)

    /// Worth trying again: transient network trouble or a server-side hiccup.
    public var isRetryable: Bool {
        switch self {
        case .timedOut, .cannotReachServer:
            true
        case let .badStatus(code):
            code == 408 || code == 429 || (500 ... 599).contains(code)
        case .cancelled, .offline, .invalidResponse, .other:
            false
        }
    }

    /// A sentence for the user. No technical codes unless there is nothing better to say.
    public var userMessage: String {
        switch self {
        case .cancelled: "The request was cancelled."
        case .timedOut: "The server took too long to respond."
        case .offline: "You appear to be offline."
        case .cannotReachServer: "The server could not be reached."
        case let .badStatus(code): "The server returned an error (\(code))."
        case .invalidResponse: "The server sent a response that could not be understood."
        case let .other(description): description
        }
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse
}

/// `HTTPClient` on top of `URLSession`, with retry and backoff.
public struct URLSessionHTTPClient: HTTPClient {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let transport: Transport
    private let sleep: Sleep
    private let retryPolicy: RetryPolicy
    private let userAgent: String

    /// - Parameters:
    ///   - cache: HTTP cache for responses; add-ons send `Cache-Control`, so repeat
    ///     visits to a catalog are served without touching the network.
    public init(userAgent: String, retryPolicy: RetryPolicy = .standard, cache: URLCache? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        let session = URLSession(configuration: configuration)
        self.init(
            userAgent: userAgent,
            retryPolicy: retryPolicy,
            transport: { try await session.data(for: $0) },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    /// Designated initialiser; tests inject the transport and the sleep function.
    public init(userAgent: String, retryPolicy: RetryPolicy, transport: @escaping Transport, sleep: @escaping Sleep) {
        self.userAgent = userAgent
        self.retryPolicy = retryPolicy
        self.transport = transport
        self.sleep = sleep
    }

    public func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        var retry = 0
        while true {
            do {
                return try await attempt(request)
            } catch {
                retry += 1
                guard error.isRetryable, let delay = retryPolicy.delay(beforeRetry: retry) else { throw error }
                do {
                    try await sleep(delay)
                } catch {
                    throw .cancelled
                }
            }
        }
    }

    private func attempt(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = request.timeout.seconds
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(urlRequest)
        } catch {
            throw Self.map(error)
        }

        guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
        guard (200 ... 299).contains(http.statusCode) else { throw .badStatus(http.statusCode) }
        return HTTPResponse(data: data, statusCode: http.statusCode)
    }

    private static func map(_ error: any Error) -> HTTPError {
        if error is CancellationError {
            return .cancelled
        }
        guard let urlError = error as? URLError else {
            return .other(error.localizedDescription)
        }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost:
            return .cannotReachServer
        default:
            return .other(urlError.localizedDescription)
        }
    }
}
