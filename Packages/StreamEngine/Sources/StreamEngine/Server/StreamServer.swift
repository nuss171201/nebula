import Foundation
import Network
import os

/// A file on disk as a `ByteSource`. Used in tests, and wherever a local file should be
/// reachable the same way a torrent's file is.
public struct FileByteSource: ByteSource {
    public let size: Int64
    private let url: URL

    public init?(url: URL) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        self.url = url
        self.size = Int64(size)
    }

    public func read(at offset: Int64, maxLength: Int, reader _: UUID) async throws -> Data {
        guard offset >= 0, offset < size, maxLength > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: maxLength) ?? Data()
    }

    public func close(reader _: UUID) async {}
}

public enum StreamServerError: Error, Sendable, Equatable {
    case couldNotStart(String)
    case notRunning
}

/// Serves byte sources to the player over HTTP on the loopback interface.
///
/// The player (libmpv) reads http(s) addresses natively and seeks with Range requests, so a
/// torrent that is still downloading is given to it as `http://127.0.0.1:<port>/<token>/<name>`.
/// The server only listens on the loopback interface, every address carries a random token,
/// and requests must be addressed to the loopback host: other programs and web pages cannot
/// find a stream by guessing, or be tricked into fetching one.
public actor StreamServer {
    /// Bytes asked of a source at a time. Small enough that a seek is noticed quickly.
    static let chunkSize = 256 * 1024

    private struct Resource {
        let source: any ByteSource
        let contentType: String
    }

    private let logger: Logger
    private let queue = DispatchQueue(label: "stream.server", qos: .userInitiated)
    private var listener: NWListener?
    private var resources: [String: Resource] = [:]
    private var connections: [UUID: Task<Void, Never>] = [:]
    public private(set) var port = 0

    public init(logSubsystem: String = "stream.engine") {
        logger = Logger(subsystem: logSubsystem, category: "server")
    }

    /// Starts listening on a free loopback port and returns it. Starting twice returns the same port.
    @discardableResult
    public func start() async throws(StreamServerError) -> Int {
        if listener != nil, port != 0 {
            return port
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .couldNotStart(error.localizedDescription)
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let ready = AsyncStream<Result<Int, StreamServerError>>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.continuation.yield(.success(Int(listener.port?.rawValue ?? 0)))
            case let .failed(error):
                ready.continuation.yield(.failure(.couldNotStart(error.localizedDescription)))
            case .cancelled:
                ready.continuation.finish()
            default:
                break
            }
        }
        listener.start(queue: queue)
        var result: Result<Int, StreamServerError> = .failure(.couldNotStart("The server stopped before it was ready."))
        for await state in ready.stream {
            result = state
            break
        }
        switch result {
        case let .success(port) where port != 0:
            self.listener = listener
            self.port = port
            return port
        case .success:
            listener.cancel()
            throw .couldNotStart("No port was assigned.")
        case let .failure(error):
            listener.cancel()
            throw error
        }
    }

    /// Makes a source reachable and returns its address. The name only decides the address's
    /// last component and the content type.
    public func publish(_ source: any ByteSource, named name: String) throws(StreamServerError) -> URL {
        guard port != 0 else { throw .notRunning }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0 ... 255)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        resources[token] = Resource(source: source, contentType: StreamContentType.forFile(named: name))
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        // A plain name: the player shows it, and reads the container type from its extension.
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        components.path = "/\(token)/\(safeName.isEmpty ? "stream" : safeName)"
        guard let url = components.url else { throw .notRunning }
        return url
    }

    /// Stops serving an address returned by `publish`: new requests for it are refused.
    /// A request already being answered goes on until its source runs dry or is closed.
    public func withdraw(_ url: URL) {
        guard let token = Self.token(inPath: url.path) else { return }
        resources[token] = nil
    }

    /// Stops listening and ends every connection.
    public func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        resources = [:]
        for task in connections.values {
            task.cancel()
        }
        connections = [:]
    }

    /// Number of requests being served. For tests.
    var activeConnectionCount: Int {
        connections.count
    }

    static func token(inPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].count == 32, parts[0].allSatisfy(\.isHexDigit) else { return nil }
        return String(parts[0])
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let box = ConnectionBox(connection)
        connection.start(queue: queue)
        connections[id] = Task { [weak self] in
            await self?.serve(box, id: id)
            box.connection.cancel()
            await self?.finished(id)
        }
    }

    private func finished(_ id: UUID) {
        connections[id] = nil
    }

    private func resource(for token: String) -> Resource? {
        resources[token]
    }

    private func serve(_ box: ConnectionBox, id: UUID) async {
        guard let headData = await box.receiveHead(), let request = HTTPRequestHead.parse(headData) else {
            await box.send(HTTPResponseHead.empty(400).serialized)
            return
        }
        guard request.isAddressedToLoopback(port: port) else {
            await box.send(HTTPResponseHead.empty(403).serialized)
            return
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            await box.send(HTTPResponseHead.empty(405, extra: [("Allow", "GET, HEAD")]).serialized)
            return
        }
        guard let token = Self.token(inPath: request.path), let resource = resource(for: token) else {
            await box.send(HTTPResponseHead.empty(404).serialized)
            return
        }
        let response = HTTPResponseHead.forResource(
            size: resource.source.size,
            contentType: resource.contentType,
            rangeHeader: request.headers["range"]
        )
        guard await box.send(response.head.serialized), request.method == "GET", let range = response.body else { return }

        // The player closes the connection when it seeks or stops; stop fetching for it at once.
        let serving = Task {
            await Self.sendBody(of: resource.source, range: range, reader: id, to: box)
        }
        box.onClose = { serving.cancel() }
        await withTaskCancellationHandler {
            await serving.value
        } onCancel: {
            serving.cancel()
        }
        await resource.source.close(reader: id)
    }

    private static func sendBody(of source: any ByteSource, range: ClosedRange<Int64>, reader: UUID, to box: ConnectionBox) async {
        var offset = range.lowerBound
        while offset <= range.upperBound, !Task.isCancelled {
            let wanted = Int(min(Int64(chunkSize), range.upperBound - offset + 1))
            guard let chunk = try? await source.read(at: offset, maxLength: wanted, reader: reader), !chunk.isEmpty, await box.send(chunk) else { return }
            offset += Int64(chunk.count)
        }
    }
}

/// One connection, with its callbacks turned into `async` calls.
private final class ConnectionBox: @unchecked Sendable {
    let connection: NWConnection
    private let lock = NSLock()
    private var closeHandler: (@Sendable () -> Void)?
    private var isClosed = false

    init(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.closed()
            default:
                break
            }
        }
    }

    /// Called once when the other side goes away. Set after the request has been read.
    var onClose: (@Sendable () -> Void)? {
        get { lock.withLock { closeHandler } }
        set {
            let alreadyClosed = lock.withLock {
                closeHandler = newValue
                return isClosed
            }
            if alreadyClosed {
                newValue?()
            } else if newValue != nil {
                watchForEnd()
            }
        }
    }

    private func closed() {
        let handler = lock.withLock {
            isClosed = true
            return closeHandler
        }
        handler?()
    }

    /// After the request nothing more is expected from the player, so the next thing to
    /// arrive is the end of the connection.
    private func watchForEnd() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            if isComplete || error != nil {
                self?.closed()
            } else if data != nil {
                self?.watchForEnd()
            }
        }
    }

    /// Reads up to the blank line that ends a request head. `nil` if the request is too long or cut short.
    func receiveHead() async -> Data? {
        var buffer = Data()
        while buffer.count <= HTTPRequestHead.maximumLength {
            if let end = buffer.range(of: HTTPRequestHead.terminator) {
                return buffer.subdata(in: buffer.startIndex ..< end.lowerBound)
            }
            guard let more = await receive(), !more.isEmpty else { return nil }
            buffer.append(more)
        }
        return nil
    }

    private func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    _ = (isComplete, error)
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Sends and waits until the data has been handed to the network, which is what keeps a
    /// fast source from running ahead of a slow reader. Returns whether it was sent.
    @discardableResult
    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}
