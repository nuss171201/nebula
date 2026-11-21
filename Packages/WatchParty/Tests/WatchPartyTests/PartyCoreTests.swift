import Foundation
import Testing
@testable import WatchParty

@Suite("Keeping players together")
struct PartyCoreTests {
    /// Two people watching the same film, the host twenty minutes in when the other arrives.
    private func partyOfTwo(guestClockOffset: Double = 0) -> (SimulatedParty, MemberID, MemberID) {
        var party = SimulatedParty()
        let host = party.join("Asha", isHost: true, clockOffset: 5000)
        party.open(SimulatedParty.film, for: host, at: 1200)
        party.advance(1)
        let guest = party.join("Ravi", clockOffset: guestClockOffset)
        party.advance(1)
        party.open(SimulatedParty.film, for: guest)
        return (party, host, guest)
    }

    @Test("Someone who joins is brought to where the party is, whatever their clock says", arguments: [0.0, -86400.0, 12345.6])
    func joinerCatchesUp(clockOffset: Double) {
        var (party, host, guest) = partyOfTwo(guestClockOffset: clockOffset)
        party.advance(8)
        #expect(party.spread < 0.15)
        #expect(party.position(of: host) > 1209)
        #expect(!party.player(guest).isPaused)
        #expect(party.player(host).jumps == 0)
        #expect(party.core(guest).status(for: party.player(guest).snapshot(at: party.time), now: party.time).activity == .ready)
    }

    @Test("A pause by one person pauses everyone at the same place")
    func pauseIsShared() {
        var (party, host, guest) = partyOfTwo()
        party.advance(8)
        party.userSetsPaused(true, for: guest)
        party.advance(2)
        #expect(party.player(host).isPaused)
        #expect(party.spread <= SyncTuning.pausedTolerance)
        let pausedAt = party.position(of: host)
        party.advance(3)
        #expect(party.position(of: host) == pausedAt)

        party.userSetsPaused(false, for: host)
        party.advance(4)
        #expect(!party.player(guest).isPaused)
        #expect(party.spread < 0.15)
        #expect(party.core(host).chat.contains { $0.text.hasPrefix("Ravi paused at 20:1") })
    }

    @Test("A jump by one person takes everyone along")
    func seekIsShared() {
        var (party, host, guest) = partyOfTwo()
        party.advance(8)
        party.userSeeks(to: 300, for: guest)
        party.advance(6)
        #expect(abs(party.position(of: host) - 306) < 0.5)
        #expect(party.spread < 0.15)
        #expect(party.core(host).chat.contains { $0.text == "Ravi jumped to 5:00." })
    }

    @Test("A jump that takes a moment to be reported is not undone in the meantime", arguments: [0.3, 1.0, 2.6])
    func slowToLandSeek(delay: Double) {
        var (party, host, guest) = partyOfTwo()
        party.advance(8)
        let jumpsBefore = party.player(guest).jumps
        party.userSeeks(to: 300, for: guest, landingAfter: delay)
        // Nothing pulled the guest back to where the party was.
        #expect(party.player(guest).jumps == jumpsBefore)
        party.advance(6)
        #expect(party.position(of: host) > 300)
        #expect(party.spread < 0.15)
    }

    @Test("With the controls left to the host, a guest's pause is undone and not passed on")
    func hostOnlyControl() {
        var (party, host, guest) = partyOfTwo()
        party.advance(8)
        party.run(on: host) { core, _ in core.setEveryoneControls(false) }
        party.advance(1)
        #expect(!party.core(guest).canControl)
        #expect(party.core(host).canControl)

        party.userSetsPaused(true, for: guest)
        party.advance(2)
        #expect(!party.player(host).isPaused)
        #expect(!party.player(guest).isPaused)
        #expect(party.nodes[guest]?.notices == ["Only the host controls playback in this party."])
        party.advance(5)
        #expect(party.spread < 0.15)
    }

    @Test("When someone's video stalls the party waits, and goes on when they are ready")
    func waitsForAStalledPlayer() {
        var (party, host, guest) = partyOfTwo()
        party.advance(8)
        party.nodes[guest]?.player.stalledUntil = party.time + 6
        party.advance(3)
        #expect(party.player(host).isPaused)
        #expect(party.core(host).waitingFor == guest)
        #expect(party.core(host).chat.contains { $0.text == "Waiting for Ravi…" })

        party.advance(6)
        #expect(party.core(host).waitingFor == nil)
        #expect(!party.player(host).isPaused)
        #expect(!party.player(guest).isPaused)
        party.advance(4)
        #expect(party.spread < 0.15)
    }

    @Test("If the person being waited for leaves, someone else lets the party go on")
    func holdSurvivesItsOwnerLeaving() {
        var (party, host, guest) = partyOfTwo()
        let third = party.join("Mei")
        party.open(SimulatedParty.film, for: third)
        party.advance(8)
        party.nodes[guest]?.player.stalledUntil = party.time + 60
        party.advance(3)
        #expect(party.core(third).waitingFor == guest)
        party.leave(guest)
        party.advance(2)
        #expect(!party.player(host).isPaused)
        #expect(!party.player(third).isPaused)
        #expect(party.core(host).chat.contains { $0.text == "Ravi left." })
    }

    @Test("A joiner's player resuming where it was left does not move the party")
    func resumeOfAJoinerIsNotACommand() {
        var (party, host, guest) = partyOfTwo()
        // The player goes to its own resume point as it opens, before it has been brought in step.
        party.userSeeks(to: 2400, for: guest)
        party.advance(8)
        #expect(abs(party.position(of: host) - 1210) < 0.5)
        #expect(party.spread < 0.15)
        #expect(party.player(host).jumps == 0)
    }

    @Test("A player that runs a little slow is kept in step without jumps")
    func driftIsCorrectedSmoothly() {
        var (party, host, guest) = partyOfTwo()
        party.advance(8)
        let jumpsBefore = party.player(guest).jumps
        party.nodes[guest]?.player.clockSkew = 0.99
        var widest = 0.0
        for _ in 0 ..< 120 {
            party.advance(1)
            widest = max(widest, party.spread)
        }
        #expect(widest < 0.2)
        #expect(party.player(guest).jumps == jumpsBefore)
        #expect(party.player(host).adjustment == 1)
    }

    @Test("Slow jumps are aimed ahead, so a player with a slow stream still arrives in step")
    func slowSeeksConverge() {
        var party = SimulatedParty()
        let host = party.join("Asha", isHost: true)
        party.open(SimulatedParty.film, for: host, at: 600)
        party.advance(1)
        let guest = party.join("Ravi")
        party.nodes[guest]?.player.seekLatency = 1.2
        party.open(SimulatedParty.film, for: guest)
        party.advance(12)
        #expect(party.spread < 0.15)
        #expect(party.player(guest).jumps <= 2)
        #expect(!party.player(host).isPaused)
    }

    @Test("Three people stay together through a pause, a jump and a change of speed")
    func threePeople() {
        var (party, host, guest) = partyOfTwo(guestClockOffset: -300)
        let third = party.join("Mei", clockOffset: 77)
        party.open(SimulatedParty.film, for: third)
        party.advance(8)
        #expect(party.spread < 0.15)

        party.userSeeks(to: 60, for: third)
        party.advance(5)
        party.userSetsPaused(true, for: host)
        party.advance(2)
        #expect(party.nodes.values.allSatisfy { $0.player.isPaused })
        #expect(party.spread <= SyncTuning.pausedTolerance)

        party.userSetsPaused(false, for: guest)
        party.nodes[guest]?.player.rate = 1.5
        party.intent(.rate(1.5), for: guest)
        party.advance(6)
        #expect(party.nodes.values.allSatisfy { $0.player.rate == 1.5 })
        #expect(party.spread < 0.15)
        #expect(party.core(host).chat.contains { $0.text == "Ravi set the speed to 1.5×." })
    }

    @Test("When the host moves on to another video the party follows, and a guest on the old one is elsewhere")
    func contentChange() {
        var (party, host, guest) = partyOfTwo()
        party.advance(8)
        party.open(SimulatedParty.episode, for: host, at: 0)
        party.advance(2)
        #expect(party.core(guest).content?.content == SimulatedParty.episode)
        #expect(party.core(guest).chat.contains { $0.text == "Asha started A Series S1 E2." })
        #expect(!party.core(guest).isWatching(party.player(guest).snapshot(at: party.time)))
        let guestPosition = party.position(of: guest)
        party.advance(3)
        // Left alone: still playing its film, no longer steered.
        #expect(party.position(of: guest) > guestPosition + 2.5)
        #expect(party.core(host).members[guest]?.status?.activity == .away)

        party.open(SimulatedParty.episode, for: guest)
        party.advance(8)
        #expect(party.spread < 0.15)
        #expect(party.position(of: host) > 10)
    }

    @Test("A guest who opens a different video goes their own way when the host has the controls, and takes the party along when everyone has")
    func guestOpeningSomethingElse() {
        var (party, host, guest) = partyOfTwo()
        party.advance(8)
        party.run(on: host) { core, _ in core.setEveryoneControls(false) }
        party.advance(1)
        party.open(SimulatedParty.episode, for: guest)
        party.advance(3)
        #expect(party.core(host).content?.content == SimulatedParty.film)
        #expect(!party.player(host).isPaused)
        #expect(party.position(of: host) > 1212)

        party.open(SimulatedParty.film, for: guest)
        party.run(on: host) { core, _ in core.setEveryoneControls(true) }
        party.advance(8)
        #expect(party.spread < 0.15)
        party.open(SimulatedParty.episode, for: guest)
        party.advance(2)
        #expect(party.core(host).content?.content == SimulatedParty.episode)
    }

    @Test("Someone who opens a video the moment they arrive, before hearing what is on, does not take the party over")
    func arrivingWithoutKnowing() {
        var party = SimulatedParty()
        party.latency = 0.4
        let host = party.join("Asha", isHost: true)
        party.open(SimulatedParty.film, for: host, at: 1200)
        party.advance(1)
        let guest = party.join("Ravi")
        // Connected, but what the host has to say is still on its way.
        party.open(SimulatedParty.episode, for: guest)
        party.advance(0.3)
        #expect(party.core(guest).content == nil)
        party.advance(5)
        #expect(party.core(host).content?.content == SimulatedParty.film)
        #expect(party.core(guest).content?.content == SimulatedParty.film)
        #expect(!party.player(host).isPaused)
        #expect(party.position(of: host) > 1205)
        #expect(party.player(host).jumps == 0)
    }

    @Test("If the party has nothing on, what a newcomer already has open becomes what it watches")
    func arrivingWithSomethingOpen() {
        var party = SimulatedParty()
        let host = party.join("Asha", isHost: true)
        party.advance(1)
        let guest = party.join("Ravi")
        party.open(SimulatedParty.film, for: guest, at: 700)
        party.advance(3)
        #expect(party.core(host).content?.content == SimulatedParty.film)
        #expect(party.core(host).chat.contains { $0.text == "Ravi started A Film." })
        party.open(SimulatedParty.film, for: host)
        party.advance(8)
        #expect(party.spread < 0.15)
        #expect(party.position(of: guest) > 708)
        #expect(party.player(guest).jumps == 0)
    }

    @Test("A file counts as a copy of whatever the party is watching")
    func filesMatchLoosely() {
        var party = SimulatedParty()
        let host = party.join("Asha", isHost: true)
        party.open(PartyContent(key: "file:film.mkv", title: "film.mkv"), for: host, at: 500)
        party.advance(1)
        let guest = party.join("Ravi")
        party.open(PartyContent(key: "file:the film (1080p).mp4", title: "the film (1080p).mp4"), for: guest)
        party.advance(8)
        #expect(party.spread < 0.15)
        #expect(party.core(host).content?.content?.key == "file:film.mkv")
    }

    @Test("At the end of the video nobody is thrown back to the start")
    func endOfVideo() {
        var (party, host, guest) = partyOfTwo()
        party.advance(8)
        party.userSeeks(to: 3595, for: host)
        party.advance(12)
        #expect(party.player(host).hasEnded)
        #expect(party.player(guest).hasEnded)
        #expect(party.position(of: guest) == 3600)
        let jumps = party.player(guest).jumps
        party.advance(5)
        #expect(party.player(guest).jumps == jumps)
    }

    @Test("Chat reaches everyone once, cleaned up")
    func chat() {
        var (party, host, guest) = partyOfTwo()
        party.advance(2)
        party.run(on: guest) { core, _ in core.sendChat("  hello\u{07} there  ") }
        party.run(on: guest) { core, _ in core.sendChat("   ") }
        party.advance(1)
        let received = party.core(host).chat.filter {
            if case .message = $0.kind {
                true
            } else {
                false
            }
        }
        #expect(received.map(\.text) == ["hello there"])
        #expect(received.first?.kind == .message(author: guest, name: "Ravi"))
        #expect(party.core(guest).chat.filter { $0.text == "hello there" }.count == 1)
    }
}
