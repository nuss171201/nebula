import Foundation
import Testing
@testable import WatchParty
import WatchPartyTestSupport

/// A player made of arithmetic that advances with real time, for driving a session.
@MainActor
final class FakePlayback: PartyPlayback {
    var onIntent: (@MainActor (LocalIntent) -> Void)?
    private(set) var notices: [String] = []
    private(set) var directives: [PlayerDirective] = []
    private var content: PartyContent?
    private var basePosition = 0.0
    private var baseTime = ContinuousClock.now
    private var isPaused = false
    private var rate = 1.0
    private var adjustment = 1.0

    var position: Double {
        guard content != nil, !isPaused else { return basePosition }
        let elapsed = baseTime.duration(to: .now)
        return basePosition + Double(elapsed.components.seconds) * rate * adjustment
            + Double(elapsed.components.attoseconds) / 1e18 * rate * adjustment
    }

    var snapshot: PlaybackSnapshot {
        PlaybackSnapshot(content: content, hasMedia: content != nil, isPaused: isPaused, position: position, duration: 7200, rate: rate)
    }

    private func rebase(to position: Double? = nil) {
        basePosition = position ?? self.position
        baseTime = .now
    }

    func open(_ content: PartyContent, at position: Double = 0) {
        self.content = content
        isPaused = false
        rebase(to: position)
    }

    func apply(_ directive: PlayerDirective) {
        directives.append(directive)
        switch directive {
        case let .setPaused(isPaused):
            rebase()
            self.isPaused = isPaused
        case let .seek(to: position):
            rebase(to: position)
        case let .setRate(rate):
            rebase()
            self.rate = rate
        case let .adjustRate(adjustment):
            rebase()
            self.adjustment = adjustment
        }
    }

    func showNotice(_ text: String) {
        notices.append(text)
    }

    /// The person at this Mac presses pause or play.
    func userSetsPaused(_ isPaused: Bool) {
        rebase()
        self.isPaused = isPaused
        onIntent?(.setPaused(isPaused))
    }

    var isPausedNow: Bool {
        isPaused
    }

    var currentAdjustment: Double {
        adjustment
    }
}

@MainActor
@Suite("A party session")
struct PartySessionTests {
    private let film = PartyContent(key: "video:movie:tt1", title: "A Film", catalog: .init(type: "movie", titleID: "tt1", videoID: "tt1"))
    private let invite: PartyInvite

    init() throws {
        invite = try PartyInvite.make(server: #require(PartyServer("https://party.example.com")))
    }

    private func makeSession(_ name: String, isHost: Bool, on network: InMemoryPartyNetwork) throws -> (PartySession, FakePlayback, InMemoryTransport) {
        let id = try #require(MemberID(name.lowercased()))
        let playback = FakePlayback()
        let transport = network.makeTransport(for: id)
        let session = PartySession(
            invite: invite, isHost: isHost, name: name, me: id, transport: transport, playback: playback, tickInterval: .milliseconds(40)
        )
        return (session, playback, transport)
    }

    @Test("A guest is brought to the host's position, a pause is shared, and the panel shows who is there")
    func joinPauseAndPeople() async throws {
        let network = InMemoryPartyNetwork()
        let (host, hostPlayer, _) = try makeSession("Asha", isHost: true, on: network)
        let (guest, guestPlayer, _) = try makeSession("Ravi", isHost: false, on: network)
        hostPlayer.open(film, at: 600)
        host.start()
        guest.start()
        defer {
            host.leave()
            guest.leave()
        }
        await eventually("they see each other") { host.people.map(\.name) == ["Asha", "Ravi"] && guest.people.map(\.name) == ["Ravi", "Asha"] }
        #expect(host.people.map(\.isHost) == [true, false])
        #expect(guest.people.map(\.isHost) == [false, true])
        await eventually("the guest learns what is on") { guest.content == film }
        #expect(guest.isElsewhere)
        #expect(guest.connection == .connected)

        guestPlayer.open(film)
        await eventually("in step") { abs(hostPlayer.position - guestPlayer.position) < 0.2 && guestPlayer.position > 600 }
        await eventually("ready") { host.people.last?.activity == .ready && !guest.isElsewhere }

        hostPlayer.userSetsPaused(true)
        await eventually("the guest is paused too") { guestPlayer.isPausedNow }
        await eventually("at the same place") { abs(hostPlayer.position - guestPlayer.position) <= SyncTuning.pausedTolerance }
        #expect(guestPlayer.notices.contains { $0.hasPrefix("Asha paused at 10:") })
        // What the host did themselves is in their chat, not flashed over their own picture.
        #expect(!hostPlayer.notices.contains { $0.hasPrefix("You ") })
        #expect(host.chat.contains { $0.text.hasPrefix("You paused at 10:") })
    }

    @Test("Chat goes both ways, and leaving is seen by the other")
    func chatAndLeaving() async throws {
        let network = InMemoryPartyNetwork()
        let (host, _, _) = try makeSession("Asha", isHost: true, on: network)
        let (guest, guestPlayer, _) = try makeSession("Ravi", isHost: false, on: network)
        host.start()
        guest.start()
        defer { host.leave() }
        await eventually("connected") { host.people.count == 2 && guest.people.count == 2 }
        host.send("ready?")
        guest.send("yes")
        await eventually("both have both lines") {
            let texts = { (session: PartySession) in session.chat.filter { $0.kind != .event }.map(\.text).sorted() }
            return texts(host) == ["ready?", "yes"] && texts(guest) == ["ready?", "yes"]
        }

        guestPlayer.apply(.adjustRate(1.05))
        guest.leave()
        #expect(guest.connection == .ended)
        // A correction in force when the party ends is taken off.
        #expect(guestPlayer.currentAdjustment == 1)
        await eventually("the host sees them go") { host.people.count == 1 }
        #expect(host.chat.last?.text == "Ravi left.")
    }

    @Test("Only the host can leave the controls to themselves, and voice is passed to the connection")
    func settingsAndVoice() async throws {
        let network = InMemoryPartyNetwork()
        let (host, _, hostTransport) = try makeSession("Asha", isHost: true, on: network)
        let (guest, _, _) = try makeSession("Ravi", isHost: false, on: network)
        host.start()
        guest.start()
        defer {
            host.leave()
            guest.leave()
        }
        await eventually("the guest may control") { guest.canControl }
        guest.setEveryoneControls(false)
        host.setEveryoneControls(false)
        await eventually("the guest no longer may") { !guest.canControl && !guest.everyoneControls }
        #expect(host.canControl)

        host.setVoice(inVoice: true)
        await eventually("the guest sees the host in the voice chat") { guest.people.last?.inVoice == true }
        #expect(host.inVoice)
        #expect(hostTransport.voiceRequests == [true])
        #expect(guest.chat.contains { $0.text == "Asha joined the voice chat." })
    }
}
