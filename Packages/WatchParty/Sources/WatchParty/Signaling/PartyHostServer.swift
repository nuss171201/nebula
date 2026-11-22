import Foundation
import Network
import os

/// A party server inside the app: it puts apps that name the same room in touch and passes
/// their sealed messages along, as `Server/signal.ts` does.
///
/// It is for people on one network (a flat, a house): the Mac that runs it is reachable from
/// the others by its address there, over plain `http`, with no relay for connections that
/// cannot be made directly. What passes through it is sealed with the invitation's secret, so
/// the plain connection gives nothing away but that a party is being arranged. For a party
/// across the internet, a server has to be hosted where everyone can reach it.
public final class PartyHostServer: Sendable {
    /// Who can reach the server.
    public enum Reach: Sendable, Equatable {
        /// Programs on this Mac only. For checks and tests.
        case thisMac
        /// Every device on the networks this Mac is on.
        case localNetwork
    }

    public enum ServerError: Error {
        case failedToStart(String)
    }

    private struct Client {
        var connection: NWConnection
        var room: String?
        var peer: MemberID?
    }

    private struct State {
        var clients: [ObjectIdentifier: Client] = [:]
        var relayedCount = 0
        var didResumeStart = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PartyHostServer")
    private let roomLimit: Int
    private let reach: Reach

    /// - Parameter port: The port to listen on, so that an invitation made today still works
    ///   tomorrow; `nil` takes any free one.
    public init(reach: Reach = .thisMac, port: UInt16? = nil, roomLimit: Int = 8) throws {
        self.roomLimit = roomLimit
        self.reach = reach
        let parameters = NWParameters.tcp
        let wanted = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: reach == .thisMac ? .ipv4(.loopback) : .ipv4(.any), port: wanted)
        parameters.allowLocalEndpointReuse = true
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters)
    }

    deinit {
        listener.cancel()
    }

    /// Starts listening and returns the address to give to others: `http://127.0.0.1:51234/`,
    /// or with this Mac's address on the local network when it can be reached from there.
    public func start() async throws -> URL {
        let host = reach == .localNetwork ? (Self.localNetworkAddress() ?? "127.0.0.1") : "127.0.0.1"
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [state, listener] update in
                let outcome: Result<URL, any Error>? = switch update {
                case .ready:
                    (listener.port?.rawValue).flatMap { URL(string: "http://\(host):\($0)/") }
                        .map { .success($0) } ?? .failure(ServerError.failedToStart("no port"))
                case let .failed(error):
                    .failure(ServerError.failedToStart("\(error)"))
                default:
                    nil
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
    }

    public func stop() {
        listener.cancel()
        dropConnections()
    }

    /// Hangs up on everyone, as a server that restarts would. The listener stays up.
    public func dropConnections() {
        let connections = state.withLock { state in
            defer { state.clients = [:] }
            return state.clients.values.map(\.connection)
        }
        connections.forEach { $0.cancel() }
    }

    /// How many sealed messages have been passed from one app to another.
    public var relayedCount: Int {
        state.withLock(\.relayedCount)
    }

    /// Who is in a room right now.
    public func peers(inRoom room: String) -> [MemberID] {
        state.withLock { state in state.clients.values.filter { $0.room == room }.compactMap(\.peer).sorted() }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        state.withLock { $0.clients[key] = Client(connection: connection) }
        connection.stateUpdateHandler = { [weak self] update in
            switch update {
            case .failed, .cancelled:
                self?.remove(key)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            if let content, let frame = try? JSONDecoder().decode(ClientFrame.self, from: content) {
                handle(frame, from: connection)
            }
            receive(on: connection)
        }
    }

    private func handle(_ frame: ClientFrame, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        switch frame {
        case let .join(room, peer):
            let (others, isFull, previous) = state.withLock { state -> ([Client], Bool, NWConnection?) in
                let others = state.clients.values.filter { $0.room == room && $0.peer != peer }
                // The same person again (their connection dropped and came back) takes their old place.
                let previous = state.clients.first { $0.value.room == room && $0.value.peer == peer && $0.key != key }
                guard previous != nil || others.count < roomLimit else { return (others, true, nil) }
                if let previous {
                    state.clients[previous.key] = nil
                }
                state.clients[key]?.room = room
                state.clients[key]?.peer = peer
                return (others, false, previous?.value.connection)
            }
            if isFull {
                send(.error(code: "room-full"), on: connection)
                return
            }
            send(.joined(peers: others.compactMap(\.peer), iceServers: []), on: connection)
            if let previous {
                previous.cancel()
            } else {
                others.forEach { send(.peerJoined(peer), on: $0.connection) }
            }
        case let .relay(to, data):
            let (sender, target) = state.withLock { state -> (Client?, Client?) in
                let sender = state.clients[key]
                let target = state.clients.values.first { $0.room == sender?.room && $0.peer == to && sender?.room != nil }
                if target != nil {
                    state.relayedCount += 1
                }
                return (sender, target)
            }
            if let from = sender?.peer, let target {
                send(.relayed(from: from, data: data), on: target.connection)
            }
        case .leave:
            connection.cancel()
        }
    }

    private func remove(_ key: ObjectIdentifier) {
        let (gone, others) = state.withLock { state -> (Client?, [Client]) in
            guard let gone = state.clients.removeValue(forKey: key) else { return (nil, []) }
            return (gone, state.clients.values.filter { $0.room == gone.room && gone.room != nil })
        }
        if let peer = gone?.peer {
            others.forEach { send(.peerLeft(peer), on: $0.connection) }
        }
    }

    private func send(_ frame: ServerFrame, on connection: NWConnection) {
        guard let data = try? JSONEncoder().encode(frame) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// This Mac's address on the network it is joined to (Wi-Fi or cable): the first private
    /// IPv4 address of an interface that is up. `nil` when it is on no such network.
    public static func localNetworkAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
            if PartyServer.isPrivateAddress(text) {
                found.append((String(cString: entry.pointee.ifa_name), text))
            }
        }
        // The built-in interfaces (en0, en1 …) before tunnels and bridges.
        return found.sorted { ($0.name.hasPrefix("en") ? 0 : 1, $0.name) < ($1.name.hasPrefix("en") ? 0 : 1, $1.name) }.first?.address
    }
}
