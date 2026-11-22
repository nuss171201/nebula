import AVFoundation
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

    init(_ name: String, invite: PartyInvite, allowsVoice: Bool = false) {
        guard let id = MemberID(name) else { preconditionFailure("bad test name") }
        self.id = id
        transport = WebRTCTransport(configuration: .init(
            invite: invite, me: id, userAgent: "tests", staysOnThisMachine: true, allowsVoice: allowsVoice, logSubsystem: "tests"
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

    @Test("When everyone proposes a change at the same moment, one side of each pair gives way and all connections survive")
    func simultaneousRenegotiation() async throws {
        let server = try LoopbackSignalServer()
        defer { server.stop() }
        let invite = try await makeInvite(server)
        let endpoints = ["alpha", "beta", "gamma"].map { TestEndpoint($0, invite: invite) }
        defer { endpoints.forEach { $0.transport.stop() } }
        await eventually("everyone connected to everyone") { endpoints.allSatisfy { $0.log.connectedPeers.count == 2 } }

        for round in 1 ... 5 {
            endpoints.forEach { $0.transport.renegotiateAll() }
            await eventually("round \(round) settles") {
                for endpoint in endpoints where await !endpoint.transport.isSettled() {
                    return false
                }
                return true
            }
        }
        for endpoint in endpoints {
            endpoint.transport.send(Data("after from \(endpoint.id)".utf8), to: nil)
        }
        await eventually("messages still flow between every pair") {
            endpoints.allSatisfy { receiver in
                endpoints.filter { $0.id != receiver.id }.allSatisfy { sender in
                    receiver.log.texts(from: sender.id) == ["after from \(sender.id)"]
                }
            }
        }
        #expect(endpoints.allSatisfy { $0.log.connectedPeers.count == 2 })
        #expect(endpoints.allSatisfy { endpoint in !endpoint.log.events.contains {
            if case .peerDisconnected = $0 {
                true
            } else {
                false
            }
        } })
    }

    /// The microphone is opened only when sound actually flows, which needs two people in the
    /// voice chat; here only one ever is. Even so, the test runs only where the question of the
    /// microphone has already been answered either way, so that nothing it does could put the
    /// system's question on screen.
    @Test(
        "Joining the voice chat alone is agreed with the others without sound flowing, and leaving it is agreed too",
        .enabled(if: AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined, "the microphone question has not been answered on this Mac")
    )
    func voiceNegotiation() async throws {
        let server = try LoopbackSignalServer()
        defer { server.stop() }
        let invite = try await makeInvite(server)
        let talker = TestEndpoint("alpha", invite: invite, allowsVoice: true)
        let listener = TestEndpoint("beta", invite: invite)
        defer {
            talker.transport.stop()
            listener.transport.stop()
        }
        await eventually("connected") { talker.log.connectedPeers == [listener.id] && listener.log.connectedPeers == [talker.id] }
        #expect(await talker.transport.voiceLinkStates() == [listener.id: .absent])

        // Asked for where voice is switched off: nothing happens.
        listener.transport.setVoice(isEnabled: true, isMuted: false)
        // Asked for where it is on: the connection gains audio, which the other side declines.
        talker.transport.setVoice(isEnabled: true, isMuted: false)
        await eventually("audio is agreed on, and silent") {
            let (mine, theirs) = await (talker.transport.voiceLinkStates(), listener.transport.voiceLinkStates())
            return mine == [listener.id: .inactive] && theirs == [talker.id: .inactive]
        }
        // The connection is none the worse for having been renegotiated.
        talker.transport.send(Data("still talking in text".utf8), to: nil)
        await eventually("messages still arrive") { listener.log.texts(from: talker.id) == ["still talking in text"] }

        talker.transport.setVoice(isEnabled: false, isMuted: false)
        talker.transport.setVoice(isEnabled: true, isMuted: true)
        talker.transport.setVoice(isEnabled: false, isMuted: false)
        listener.transport.send(Data("and back".utf8), to: nil)
        await eventually("and in the other direction, after joining and leaving again") { talker.log.texts(from: listener.id) == ["and back"] }
        #expect(await talker.transport.voiceLinkStates() == [listener.id: .inactive])
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
