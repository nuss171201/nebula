import Foundation
@testable import WatchParty

/// A player that exists only as numbers: it advances when it plays, takes a while to land a jump,
/// and can be told to stall.
struct SimulatedPlayer {
    var content: PartyContent?
    var hasMedia = false
    var isPaused = false
    var hasEnded = false
    var position = 0.0
    var duration: Double? = 3600
    var rate = 1.0
    var adjustment = 1.0
    /// How much faster or slower than real time this player's clock runs.
    var clockSkew = 1.0
    /// How long a jump takes before the picture moves again.
    var seekLatency = 0.15
    var stalledUntil = 0.0
    /// How long the player takes to get round to a jump it was asked for; until then it plays on where it was.
    var seekStartDelay = 0.0
    private var queuedSeek: (target: Double, at: Double)?
    /// A jump the person asked for that has not been reported as landed yet.
    var hasPendingJump = false
    var directives: [PlayerDirective] = []

    func isStalled(at time: Double) -> Bool {
        time < stalledUntil
    }

    func snapshot(at time: Double) -> PlaybackSnapshot {
        PlaybackSnapshot(
            content: content, hasMedia: hasMedia, isPaused: isPaused, isStalled: hasMedia && isStalled(at: time),
            hasPendingJump: hasPendingJump, hasEnded: hasEnded, position: position, duration: duration, rate: rate
        )
    }

    mutating func advance(by seconds: Double, at time: Double) {
        if let queued = queuedSeek, time >= queued.at {
            queuedSeek = nil
            land(queued.target, at: time)
        }
        guard hasMedia, !isPaused, !hasEnded, !isStalled(at: time) else { return }
        position += seconds * rate * adjustment * clockSkew
        if let duration, position >= duration {
            position = duration
            hasEnded = true
        }
    }

    mutating func apply(_ directive: PlayerDirective, at time: Double) {
        directives.append(directive)
        switch directive {
        case let .setPaused(isPaused):
            self.isPaused = isPaused
        case let .seek(to: target):
            // A jump from the party takes the place of one of the person's own.
            hasPendingJump = false
            if seekStartDelay > 0 {
                queuedSeek = (target, time + seekStartDelay)
            } else {
                land(target, at: time)
            }
        case let .setRate(rate):
            self.rate = rate
        case let .adjustRate(adjustment):
            self.adjustment = adjustment
        }
    }

    private mutating func land(_ target: Double, at time: Double) {
        position = min(target, duration ?? target)
        hasEnded = false
        stalledUntil = max(stalledUntil, time + seekLatency)
    }

    var jumps: Int {
        directives.filter {
            if case .seek = $0 {
                true
            } else {
                false
            }
        }.count
    }
}

/// Several apps in one party, each with its own clock and player, joined by a network that takes
/// time to deliver. Time only moves when the test moves it.
struct SimulatedParty {
    struct Node {
        var core: PartyCore
        var player = SimulatedPlayer()
        /// This Mac's clock reads true time plus this.
        var clockOffset: Double
        var notices: [String] = []
        var isOnline = true
    }

    private struct Delivery {
        var at: Double
        var from: MemberID
        var to: MemberID
        var message: PartyMessage
    }

    private(set) var time = 0.0
    var nodes: [MemberID: Node] = [:]
    /// One-way delay between any two apps, in seconds.
    var latency = 0.06
    private var inFlight: [Delivery] = []
    private var sinceTick = 0.0
    static let step = 0.05

    static let film = PartyContent(key: "video:movie:tt1", title: "A Film", catalog: .init(type: "movie", titleID: "tt1", videoID: "tt1"))
    static let episode = PartyContent(key: "video:series:tt2:1:2", title: "A Series S1 E2", catalog: .init(type: "series", titleID: "tt2", videoID: "tt2:1:2"))

    /// Adds someone and connects them to everyone already there.
    @discardableResult
    mutating func join(_ name: String, isHost: Bool = false, clockOffset: Double = 0) -> MemberID {
        // Ids in order of joining, so tests can say who has the lowest.
        guard let id = MemberID("m\(nodes.count)-\(name.lowercased())") else { preconditionFailure("bad test name") }
        let others = nodes.keys.filter { nodes[$0]?.isOnline == true }
        nodes[id] = Node(core: PartyCore(me: id, name: name, isHost: isHost), clockOffset: clockOffset)
        for other in others {
            run(on: id) { core, now in core.peerConnected(other, now: now) }
            run(on: other) { core, now in core.peerConnected(id, now: now) }
        }
        return id
    }

    /// Takes someone out, as when their app quits.
    mutating func leave(_ id: MemberID) {
        nodes[id]?.isOnline = false
        inFlight.removeAll { $0.from == id || $0.to == id }
        for other in nodes.keys where other != id && nodes[other]?.isOnline == true {
            run(on: other) { core, now in core.peerDisconnected(id, now: now) }
        }
    }

    /// Opens a video in someone's player, as if its file had loaded at once.
    mutating func open(_ content: PartyContent, for id: MemberID, at position: Double = 0, isPaused: Bool = false) {
        nodes[id]?.player.content = content
        nodes[id]?.player.hasMedia = true
        nodes[id]?.player.hasEnded = false
        nodes[id]?.player.position = position
        nodes[id]?.player.isPaused = isPaused
    }

    /// The person at this Mac presses pause or play.
    mutating func userSetsPaused(_ isPaused: Bool, for id: MemberID) {
        nodes[id]?.player.isPaused = isPaused
        intent(.setPaused(isPaused), for: id)
    }

    /// The person at this Mac jumps to a position.
    mutating func userSeeks(to position: Double, for id: MemberID) {
        nodes[id]?.player.position = position
        intent(.seeked(to: position), for: id)
    }

    /// The person jumps, and the player takes `delay` seconds to say that the jump has landed:
    /// its position is already the new one, but nobody has been told that this was the person's doing.
    mutating func userSeeks(to position: Double, for id: MemberID, landingAfter delay: Double) {
        nodes[id]?.player.position = position
        nodes[id]?.player.hasPendingJump = true
        advance(delay)
        guard nodes[id]?.player.hasPendingJump == true else { return }
        nodes[id]?.player.hasPendingJump = false
        intent(.seeked(to: nodes[id]?.player.position ?? position), for: id)
    }

    mutating func intent(_ intent: LocalIntent, for id: MemberID) {
        guard let snapshot = nodes[id]?.player.snapshot(at: time) else { return }
        run(on: id) { core, now in core.localIntent(intent, snapshot: snapshot, now: now) }
    }

    mutating func run(on id: MemberID, _ body: (inout PartyCore, Double) -> [PartyCore.Effect]) {
        guard var node = nodes[id], node.isOnline else { return }
        let effects = body(&node.core, time + node.clockOffset)
        for effect in effects {
            switch effect {
            case let .send(message, to):
                let targets = to.map { [$0] } ?? Array(node.core.members.keys)
                for target in targets {
                    inFlight.append(Delivery(at: time + latency, from: id, to: target, message: message))
                }
            case let .player(directive):
                node.player.apply(directive, at: time)
            case let .notice(text):
                node.notices.append(text)
            }
        }
        nodes[id] = node
    }

    /// Lets time pass: players advance, messages arrive, and every app ticks four times a second.
    mutating func advance(_ seconds: Double) {
        let steps = Int((seconds / Self.step).rounded())
        for _ in 0 ..< steps {
            time += Self.step
            for id in nodes.keys {
                nodes[id]?.player.advance(by: Self.step, at: time)
            }
            let due = inFlight.filter { $0.at <= time + 1e-9 }
            inFlight.removeAll { $0.at <= time + 1e-9 }
            for delivery in due {
                run(on: delivery.to) { core, now in core.receive(delivery.message, from: delivery.from, now: now) }
            }
            sinceTick += Self.step
            if sinceTick >= 0.25 - 1e-9 {
                sinceTick = 0
                for id in nodes.keys.sorted() {
                    guard let snapshot = nodes[id]?.player.snapshot(at: time) else { continue }
                    run(on: id) { core, now in core.tick(snapshot, now: now) }
                }
            }
        }
    }

    func position(of id: MemberID) -> Double {
        nodes[id]?.player.position ?? -1
    }

    func player(_ id: MemberID) -> SimulatedPlayer {
        nodes[id]?.player ?? SimulatedPlayer()
    }

    func core(_ id: MemberID) -> PartyCore {
        guard let node = nodes[id] else { preconditionFailure("no such member") }
        return node.core
    }

    /// The widest gap between any two players' positions.
    var spread: Double {
        let positions = nodes.values.filter(\.isOnline).map(\.player.position)
        return (positions.max() ?? 0) - (positions.min() ?? 0)
    }
}
