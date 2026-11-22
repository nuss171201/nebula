import Foundation
import Testing
@testable import WatchParty

@Suite("Invitations")
struct PartyInviteTests {
    @Test("Server addresses", arguments: [
        ("https://party.example.com", "https://party.example.com/", "wss://party.example.com/ws"),
        ("https://example.com/party", "https://example.com/party/", "wss://example.com/party/ws"),
        ("  https://EXAMPLE.com:8443/?x=1#frag ", "https://EXAMPLE.com:8443/", "wss://EXAMPLE.com:8443/ws"),
        ("http://127.0.0.1:8787", "http://127.0.0.1:8787/", "ws://127.0.0.1:8787/ws"),
        ("http://localhost:8787/", "http://localhost:8787/", "ws://localhost:8787/ws"),
    ])
    func serverAddresses(input: String, shown: String, socket: String) throws {
        let server = try #require(PartyServer(input))
        #expect(server.url.absoluteString == shown)
        #expect(server.socketURL.absoluteString == socket)
    }

    @Test("Addresses that are refused", arguments: [
        "", "party.example.com", "http://party.example.com", "ftp://example.com", "https://", "https://user:secret@example.com", "file:///tmp/x",
    ])
    func refusedAddresses(input: String) {
        #expect(PartyServer(input) == nil)
    }

    @Test("A link carries the server and the secret, and reads back as the same party")
    func linkRoundTrip() throws {
        let server = try #require(PartyServer("https://party.example.com"))
        let invite = PartyInvite.make(server: server)
        #expect(invite.link == "https://party.example.com/#" + invite.code)
        #expect(invite.code.count == 22)
        #expect(PartyInvite(invite.link) == invite)
        #expect(PartyInvite("  " + invite.link + "\n") == invite)
        // The code alone is enough where the server is known, and nothing where it is not.
        #expect(PartyInvite(invite.code, defaultServer: server) == invite)
        #expect(PartyInvite(invite.code) == nil)
        // A link names its own server, whatever the app would otherwise use.
        let other = try #require(PartyServer("https://other.example.org"))
        #expect(PartyInvite(invite.link, defaultServer: other)?.server == server)
    }

    @Test("Things that are not invitations", arguments: [
        "", "hello", "https://party.example.com/", "https://party.example.com/#", "https://party.example.com/#short",
        "https://party.example.com/#not base64 at all!!", "http://elsewhere.example.com/#AAAAAAAAAAAAAAAAAAAAAA",
    ])
    func notInvites(text: String) {
        #expect(PartyInvite(text, defaultServer: nil) == nil)
    }

    @Test("The room name and the key come from the secret, and the room name does not give it away")
    func derivedValues() throws {
        let server = try #require(PartyServer("https://party.example.com"))
        let first = PartyInvite(server: server, secret: Data(repeating: 7, count: 16))
        let same = PartyInvite(server: server, secret: Data(repeating: 7, count: 16))
        let other = PartyInvite(server: server, secret: Data(repeating: 8, count: 16))
        #expect(first.roomID == same.roomID)
        #expect(first.roomID != other.roomID)
        #expect(first.roomID.count == 32)
        #expect(!first.roomID.contains(first.code))
        #expect(first.roomID.allSatisfy { $0.isHexDigit })
    }

    @Test("Sealed signalling opens only with the party's key, for the people it was between")
    func sealing() throws {
        let server = try #require(PartyServer("https://party.example.com"))
        let invite = PartyInvite.make(server: server)
        let (alpha, beta, gamma) = try (#require(MemberID("alpha")), #require(MemberID("beta")), #require(MemberID("gamma")))
        let payload = SignalPayload.description(isOffer: true, sdp: "v=0\r\n")
        let sealed = try #require(invite.seal.seal(payload, from: alpha, to: beta))
        #expect(!sealed.contains("v=0"))
        #expect(invite.seal.open(sealed, from: alpha, to: beta) == payload)
        // Not as if from or for someone else, not with another party's key, not after tampering.
        #expect(invite.seal.open(sealed, from: gamma, to: beta) == nil)
        #expect(invite.seal.open(sealed, from: alpha, to: gamma) == nil)
        #expect(PartyInvite.make(server: server).seal.open(sealed, from: alpha, to: beta) == nil)
        #expect(invite.seal.open(String(sealed.dropLast(4)) + "AAAA", from: alpha, to: beta) == nil)
        #expect(invite.seal.open("not sealed", from: alpha, to: beta) == nil)
        // Sealing the same thing twice does not give the same text.
        #expect(invite.seal.seal(payload, from: alpha, to: beta) != sealed)
    }
}

@Suite("Messages between apps")
struct PartyMessageTests {
    private static let author = MemberID("alpha") ?? .random()

    static let samples: [PartyMessage] = [
        .hello(name: "Asha", protocolVersion: 1),
        .status(MemberStatus(activity: .stalled, title: "A Film", position: 12.5, inVoice: true, isMuted: true)),
        .ping(id: 3, sentAt: 1234.5),
        .pong(id: 3, sentAt: 1234.5, receivedAt: 99.25),
        .playback(PlaybackWire(
            position: 61.5, sentAt: 10, isPaused: true, rate: 1.5, holder: author, reason: .wait,
            version: RegisterVersion(counter: 4, author: author)
        )),
        .content(SharedContent(
            content: PartyContent(key: "video:movie:tt1", title: "A Film", catalog: .init(type: "movie", titleID: "tt1", videoID: "tt1")),
            version: RegisterVersion(counter: 2, author: author)
        )),
        .settings(RoomSettings(hostID: author, everyoneControls: false, version: RegisterVersion(counter: 5, author: author))),
        .chat(ChatWire(id: "abc", text: "hello")),
        .caughtUp,
    ]

    @Test("Every message survives the trip", arguments: samples)
    func roundTrip(message: PartyMessage) throws {
        let data = try #require(message.encoded())
        #expect(PartyMessage.decode(data) == message)
    }

    @Test("What is not a message is not acted on", arguments: [
        "", "{}", "[]", #"{"t":"dance","d":{}}"#, #"{"t":"ping","d":{"id":"x"}}"#, #"{"t":"hello"}"#,
        #"{"t":"settings","d":{"hostID":"NOT AN ID","everyoneControls":true,"version":{"counter":1,"author":"a"}}}"#,
    ])
    func malformed(text: String) {
        #expect(PartyMessage.decode(Data(text.utf8)) == nil)
    }

    @Test("A reason or an activity from a newer version is read as the nearest thing known")
    func lenientEnums() {
        let playback = #"{"t":"playback","d":{"position":1,"sentAt":2,"isPaused":false,"rate":1,"reason":"rewind","version":{"counter":1,"author":"a"}}}"#
        guard case let .playback(wire)? = PartyMessage.decode(Data(playback.utf8)) else {
            Issue.record("not decoded")
            return
        }
        #expect(wire.reason == .user)
        let status = #"{"t":"status","d":{"activity":"dancing","inVoice":false,"isMuted":false}}"#
        #expect(PartyMessage.decode(Data(status.utf8)) == .status(MemberStatus(activity: .away)))
    }

    @Test("Numbers a player could not be sent to are refused")
    func implausiblePlayback() throws {
        let author = try #require(MemberID("a"))
        var wire = PlaybackWire(position: 10, sentAt: 1, isPaused: false, rate: 1, holder: nil, reason: .user, version: .init(counter: 1, author: author))
        #expect(wire.isPlausible)
        wire.rate = 0
        #expect(!wire.isPlausible)
        wire.rate = 1
        wire.position = -5
        #expect(!wire.isPlausible)
        wire.position = .infinity
        #expect(!wire.isPlausible)
    }

    @Test("Member ids", arguments: [("abc-123", true), ("", false), ("Has Space", false), ("UPPER", false), (String(repeating: "a", count: 65), false)])
    func memberIDs(text: String, isValid: Bool) {
        #expect((MemberID(text) != nil) == isValid)
    }

    @Test("Text from other apps is cleaned and cut")
    func cleaning() {
        #expect(WireLimits.clean("  a\u{0}b\u{1B}[31m \n", limit: 40) == "ab[31m")
        #expect(WireLimits.clean(String(repeating: "x", count: 100), limit: 40).count == 40)
        #expect(WireLimits.clean("two\nlines", limit: 40) == "two\nlines")
    }
}

@Suite("Comparing clocks")
struct ClockSyncTests {
    @Test("The quickest exchange gives the estimate")
    func picksQuickest() {
        var clock = ClockSync()
        #expect(clock.offset == nil)
        // The other clock is 100 s ahead. A slow, lopsided exchange first: 0.4 s out, 0.1 s back.
        clock.addSample(sentAt: 10, remoteAt: 110.4, receivedAt: 10.5)
        #expect(abs((clock.offset ?? 0) - 100.15) < 1e-9)
        // Then a quick, even one.
        clock.addSample(sentAt: 20, remoteAt: 120.02, receivedAt: 20.04)
        #expect(abs((clock.offset ?? 0) - 100) < 1e-9)
        #expect(abs((clock.roundTrip ?? 0) - 0.04) < 1e-9)
        // A later slow one does not displace it.
        clock.addSample(sentAt: 30, remoteAt: 130.9, receivedAt: 31)
        #expect(abs((clock.offset ?? 0) - 100) < 1e-9)
    }

    @Test("Impossible exchanges are left out, and old ones are forgotten")
    func discards() {
        var clock = ClockSync()
        clock.addSample(sentAt: 10, remoteAt: 50, receivedAt: 9)
        clock.addSample(sentAt: 10, remoteAt: 50, receivedAt: 25)
        clock.addSample(sentAt: 10, remoteAt: .nan, receivedAt: 10.1)
        #expect(clock.offset == nil)
        clock.addSample(sentAt: 0, remoteAt: 5, receivedAt: 0.01)
        for index in 1 ... 8 {
            clock.addSample(sentAt: Double(index), remoteAt: Double(index) + 7.1, receivedAt: Double(index) + 0.2)
        }
        // The very quick first exchange has aged out; the estimate follows the clock as it is now.
        #expect(abs((clock.offset ?? 0) - 7) < 1e-9)
    }

    @Test("Catching up is gentle, bounded and stops when the gap has closed")
    func rateAdjustment() {
        #expect(SyncTuning.rateAdjustment(forGap: 0.05, current: 1) == 1)
        #expect(SyncTuning.rateAdjustment(forGap: -0.2, current: 1) == 1.05)
        #expect(SyncTuning.rateAdjustment(forGap: 0.2, current: 1) == 0.95)
        #expect(SyncTuning.rateAdjustment(forGap: -1.4, current: 1) == 1.08)
        #expect(SyncTuning.rateAdjustment(forGap: 1.4, current: 1) == 0.92)
        // Once correcting, it carries on inside the band where it would not have started.
        #expect(SyncTuning.rateAdjustment(forGap: -0.08, current: 1.05) == 1.02)
        #expect(SyncTuning.rateAdjustment(forGap: -0.02, current: 1.02) == 1)
    }
}
