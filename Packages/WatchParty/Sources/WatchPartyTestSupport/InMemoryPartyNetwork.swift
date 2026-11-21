import Foundation
import os
import WatchParty

/// A party without a network: transports made here are connected to each other the moment they
/// start, and what one sends the others receive. For tests of everything above the connection.
public final class InMemoryPartyNetwork: Sendable {
    private struct State {
        var online: [MemberID: AsyncStream<TransportEvent>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func makeTransport(for id: MemberID) -> InMemoryTransport {
        InMemoryTransport(id: id, network: self)
    }

    fileprivate func connect(_ id: MemberID, _ continuation: AsyncStream<TransportEvent>.Continuation) {
        let others = state.withLock { state in
            defer { state.online[id] = continuation }
            return state.online
        }
        continuation.yield(.signaling(.connected))
        for (other, theirs) in others {
            continuation.yield(.peerConnected(other))
            theirs.yield(.peerConnected(id))
        }
    }

    fileprivate func disconnect(_ id: MemberID) {
        let others = state.withLock { state -> [AsyncStream<TransportEvent>.Continuation] in
            guard state.online.removeValue(forKey: id) != nil else { return [] }
            return Array(state.online.values)
        }
        others.forEach { $0.yield(.peerDisconnected(id)) }
    }

    fileprivate func deliver(_ data: Data, from sender: MemberID, to recipient: MemberID?) {
        let targets = state.withLock { state -> [AsyncStream<TransportEvent>.Continuation] in
            guard state.online[sender] != nil else { return [] }
            return state.online.filter { $0.key != sender && (recipient == nil || recipient == $0.key) }.map(\.value)
        }
        targets.forEach { $0.yield(.data(data, from: sender)) }
    }
}

public final class InMemoryTransport: PartyTransport {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let id: MemberID
    private let network: InMemoryPartyNetwork
    private let voice = OSAllocatedUnfairLock(initialState: [Bool]())

    fileprivate init(id: MemberID, network: InMemoryPartyNetwork) {
        self.id = id
        self.network = network
        (events, continuation) = AsyncStream<TransportEvent>.makeStream()
    }

    /// Every voice setting asked for, in order: whether it was to be in the voice chat.
    public var voiceRequests: [Bool] {
        voice.withLock { $0 }
    }

    public func start() {
        network.connect(id, continuation)
    }

    public func send(_ data: Data, to recipient: MemberID?) {
        network.deliver(data, from: id, to: recipient)
    }

    public func setVoice(isEnabled: Bool, isMuted _: Bool) {
        voice.withLock { $0.append(isEnabled) }
    }

    public func stop() {
        network.disconnect(id)
        continuation.finish()
    }
}
