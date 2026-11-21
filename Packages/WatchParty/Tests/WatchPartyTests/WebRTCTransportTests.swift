import Foundation
import os
import Testing
@testable import WatchParty
import WatchPartyTestSupport

/// Collects what a transport reports, so a test can wait for something to have happened.
final class EventLog: Sendable {
    private let stored = OSAllocatedUnfairLock(initialState: [TransportEvent]())

    func record(_ event: TransportEvent) {
        stored.withLock { $0.append(event) }
    }

    var events: [TransportEvent] {
        stored.withLock { $0 }
    }

    var connectedPeers: Set<MemberID> {
        var peers: Set<MemberID> = []
        for event in events {
            switch event {
            case let .peerConnected(id): peers.insert(id)
            case let .peerDisconnected(id): peers.remove(id)
            default: break
            }
        }
        return peers
    }

    func texts(from sender: MemberID) -> [String] {
        events.compactMap { event in
            if case let .data(data, from) = event, from == sender {
                return String(data: data, encoding: .utf8)
            }
            return nil
        }
    }
}

/// One app's connection to a party, on this machine only and without voice.
struct TestEndpoint {
    let id: MemberID
    let transport: WebRTCTransport
    let log = EventLog()

    init(_ name: String, invite: PartyInvite) {
        guard let id = MemberID(name) else { preconditionFailure("bad test name") }
        self.id = id
        transport = WebRTCTransport(configuration: .init(
            invite: invite, me: id, userAgent: "tests", staysOnThisMachine: true, allowsVoice: false, logSubsystem: "tests"
        ))
        let (events, log) = (transport.events, log)
        Task {
            for await event in events {
                log.record(event)
            }
        }
        transport.start()
    }
}

/// Polls until `condition` holds, failing the test if it does not within the time allowed.
func eventually(
    _ what: String,
    within seconds: Double = 15,
    isolation _: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("timed out waiting for: \(what)", sourceLocation: sourceLocation)
}

@Suite("Direct connections between apps", .serialized)
struct WebRTCTransportTests {
    private func makeInvite(_ server: LoopbackSignalServer) async throws -> PartyInvite {
        let address = try await server.start()
        let partyServer = try #require(PartyServer(address.absoluteString))
        return PartyInvite.make(server: partyServer)
    }

    @Test("Two apps with the same invitation connect and exchange messages both ways")
    func twoPeers() async throws {
        let server = try LoopbackSignalServer()
        defer { server.stop() }
        let invite = try await makeInvite(server)
        let first = TestEndpoint("alpha", invite: invite)
        let second = TestEndpoint("beta", invite: invite)
        defer {
            first.transport.stop()
            second.transport.stop()
        }
        await eventually("both sides connected") {
            first.log.connectedPeers == [second.id] && second.log.connectedPeers == [first.id]
        }
        first.transport.send(Data("from alpha".utf8), to: nil)
        second.transport.send(Data("from beta".utf8), to: first.id)
        await eventually("messages delivered") {
            second.log.texts(from: first.id) == ["from alpha"] && first.log.texts(from: second.id) == ["from beta"]
        }
        #expect(server.peers(inRoom: invite.roomID) == [first.id, second.id])
    }

    @Test("Three apps are all connected to each other, and a message to one person reaches only them")
    func threePeers() async throws {
        let server = try LoopbackSignalServer()
        defer { server.stop() }
        let invite = try await makeInvite(server)
        let endpoints = ["alpha", "beta", "gamma"].map { TestEndpoint($0, invite: invite) }
        defer { endpoints.forEach { $0.transport.stop() } }
        await eventually("everyone connected to everyone") {
            endpoints.allSatisfy { $0.log.connectedPeers.count == 2 }
        }
        endpoints[0].transport.send(Data("for gamma".utf8), to: endpoints[2].id)
        endpoints[1].transport.send(Data("for all".utf8), to: nil)
        await eventually("messages delivered") {
            endpoints[2].log.texts(from: endpoints[0].id) == ["for gamma"]
                && endpoints[2].log.texts(from: endpoints[1].id) == ["for all"]
                && endpoints[0].log.texts(from: endpoints[1].id) == ["for all"]
        }
        #expect(endpoints[1].log.texts(from: endpoints[0].id).isEmpty)
    }

    @Test("Someone leaving is noticed by the others")
    func leaving() async throws {
        let server = try LoopbackSignalServer()
        defer { server.stop() }
        let invite = try await makeInvite(server)
        let first = TestEndpoint("alpha", invite: invite)
        let second = TestEndpoint("beta", invite: invite)
        defer { first.transport.stop() }
        await eventually("connected") { first.log.connectedPeers == [second.id] }
        second.transport.stop()
        await eventually("the other side sees them go") { first.log.connectedPeers.isEmpty }
    }

    @Test("People stay connected when the signalling server goes away, and a newcomer gets in once it is back")
    func signalingLoss() async throws {
        let server = try LoopbackSignalServer()
        defer { server.stop() }
        let invite = try await makeInvite(server)
        let first = TestEndpoint("alpha", invite: invite)
        let second = TestEndpoint("beta", invite: invite)
        defer {
            first.transport.stop()
            second.transport.stop()
        }
        await eventually("connected") { first.log.connectedPeers == [second.id] }
        server.dropConnections()
        await eventually("both notice the server is gone") {
            first.log.events.contains(.signaling(.retrying(attempt: 1))) && second.log.events.contains(.signaling(.retrying(attempt: 1)))
        }
        first.transport.send(Data("still here".utf8), to: nil)
        await eventually("the direct connection still carries messages") { second.log.texts(from: first.id) == ["still here"] }
        #expect(first.log.connectedPeers == [second.id])

        await eventually("both are back in the room") { server.peers(inRoom: invite.roomID).count == 2 }
        let third = TestEndpoint("gamma", invite: invite)
        defer { third.transport.stop() }
        await eventually("the newcomer reaches both") { third.log.connectedPeers == [first.id, second.id] }
        // Rejoining the room did not make the two who were connected connect a second time.
        #expect(first.log.events.filter { $0 == .peerConnected(second.id) }.count == 1)
    }

    @Test("An invitation to a different party does not get in, though the server is the same")
    func differentInvite() async throws {
        let server = try LoopbackSignalServer()
        defer { server.stop() }
        let invite = try await makeInvite(server)
        let other = PartyInvite.make(server: invite.server)
        let first = TestEndpoint("alpha", invite: invite)
        let stranger = TestEndpoint("beta", invite: other)
        defer {
            first.transport.stop()
            stranger.transport.stop()
        }
        await eventually("both in their rooms") {
            first.log.events.contains(.signaling(.connected)) && stranger.log.events.contains(.signaling(.connected))
        }
        try await Task.sleep(for: .seconds(1))
        #expect(first.log.connectedPeers.isEmpty)
        #expect(server.relayedCount == 0)
    }

    @Test("A full room turns the next person away")
    func roomFull() async throws {
        let server = try LoopbackSignalServer(roomLimit: 1)
        defer { server.stop() }
        let invite = try await makeInvite(server)
        let first = TestEndpoint("alpha", invite: invite)
        defer { first.transport.stop() }
        await eventually("first is in") { first.log.events.contains(.signaling(.connected)) }
        let second = TestEndpoint("beta", invite: invite)
        defer { second.transport.stop() }
        await eventually("the second is refused") { second.log.events.contains(.failed(.roomFull)) }
        #expect(first.log.connectedPeers.isEmpty)
    }
}
