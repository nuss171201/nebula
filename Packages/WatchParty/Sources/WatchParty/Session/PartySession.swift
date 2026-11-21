import Foundation
import Observation

/// Being in a party: connects, keeps this Mac's player with the others, and holds what the
/// party's panel shows (who is here, the chat, what is being watched).
///
/// The decisions are `PartyCore`'s; this class feeds it what happens, with the time, and carries
/// out what it answers.
@MainActor
@Observable
public final class PartySession {
    public enum Connection: Sendable, Equatable {
        case connecting
        case connected
        /// The signalling server cannot be reached right now. People already connected are unaffected.
        case reconnecting
        /// The party could not be joined; a sentence for the person.
        case failed(String)
        case ended
    }

    /// Someone in the party, as listed in its panel.
    public struct Person: Sendable, Equatable, Identifiable {
        public var id: MemberID
        public var name: String
        public var isMe: Bool
        public var isHost: Bool
        public var activity: MemberStatus.Activity
        /// What they have open, when it is not what the party is watching.
        public var otherTitle: String?
        public var inVoice: Bool
        public var isMuted: Bool
    }

    public let invite: PartyInvite
    public let isHost: Bool
    public private(set) var connection = Connection.connecting
    public private(set) var people: [Person] = []
    public private(set) var chat: [PartyCore.ChatEntry] = []
    /// What the party is watching, once someone has started something.
    public private(set) var content: PartyContent?
    /// Whether this Mac's player is on something other than what the party is watching (or on nothing).
    public private(set) var isElsewhere = false
    /// The name of whoever the party has paused for.
    public private(set) var waitingFor: String?
    public private(set) var canControl = false
    public private(set) var everyoneControls = true
    public private(set) var inVoice = false
    public private(set) var isMuted = false

    @ObservationIgnored private var core: PartyCore
    @ObservationIgnored private let transport: any PartyTransport
    @ObservationIgnored private let playback: any PartyPlayback
    @ObservationIgnored private let startedAt = ContinuousClock.now
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var flashedEntries = 0

    /// - Parameters:
    ///   - isHost: Whether this person is starting the party rather than joining it.
    ///   - name: What the others see this person as.
    public init(
        invite: PartyInvite,
        isHost: Bool,
        name: String,
        me: MemberID = .random(),
        transport: any PartyTransport,
        playback: any PartyPlayback,
        tickInterval: Duration = .milliseconds(250)
    ) {
        self.invite = invite
        self.isHost = isHost
        self.transport = transport
        self.playback = playback
        self.tickInterval = tickInterval
        core = PartyCore(me: me, name: name.isEmpty ? "Someone" : name, isHost: isHost)
        refresh()
    }

    public var me: MemberID {
        core.me
    }

    /// Seconds on this session's own clock, which keeps counting while the Mac sleeps.
    private var now: TimeInterval {
        let elapsed = startedAt.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    public func start() {
        guard eventTask == nil, connection != .ended else { return }
        playback.onIntent = { [weak self] intent in
            guard let self else { return }
            step { core, now in core.localIntent(intent, snapshot: self.playback.snapshot, now: now) }
        }
        let events = transport.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        tickTask = Task { [weak self, tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard let self, !Task.isCancelled else { return }
                step { core, now in core.tick(self.playback.snapshot, now: now) }
            }
        }
        transport.start()
    }

    /// Leaves the party. The player carries on by itself.
    public func leave() {
        guard connection != .ended else { return }
        finish(as: .ended)
    }

    private func finish(as outcome: Connection) {
        tickTask?.cancel()
        eventTask?.cancel()
        transport.stop()
        playback.onIntent = nil
        // Whatever small correction was in force must not outlive the party.
        playback.apply(.adjustRate(1))
        connection = outcome
        waitingFor = nil
    }

    // MARK: - What the person here does

    public func send(_ text: String) {
        step { core, _ in core.sendChat(text) }
    }

    /// For the host: whether everyone, or only they, may pause, seek and choose what is watched.
    public func setEveryoneControls(_ everyoneControls: Bool) {
        step { core, _ in core.setEveryoneControls(everyoneControls) }
    }

    /// Joins or leaves the voice chat. The app asks for the microphone before joining.
    public func setVoice(inVoice: Bool, isMuted: Bool = false) {
        transport.setVoice(isEnabled: inVoice, isMuted: isMuted)
        step { core, _ in
            core.setVoice(inVoice: inVoice, isMuted: inVoice && isMuted)
            return []
        }
    }

    // MARK: - Running the core

    private func handle(_ event: TransportEvent) {
        guard connection != .ended else { return }
        switch event {
        case let .signaling(state):
            switch state {
            case .connecting: connection = .connecting
            case .connected: connection = .connected
            // Not having got in at all yet reads as still connecting; having been in, as reconnecting.
            case .retrying: connection = connection == .connecting ? .connecting : .reconnecting
            }
        case let .peerConnected(id):
            step { core, now in core.peerConnected(id, now: now) }
        case let .peerDisconnected(id):
            step { core, now in core.peerDisconnected(id, now: now) }
        case let .data(data, sender):
            guard let message = PartyMessage.decode(data) else { return }
            step { core, now in core.receive(message, from: sender, now: now) }
        case let .failed(failure):
            finish(as: .failed(failure.userMessage))
        }
    }

    private func step(_ body: (inout PartyCore, TimeInterval) -> [PartyCore.Effect]) {
        guard connection != .ended else { return }
        let effects = body(&core, now)
        for effect in effects {
            switch effect {
            case let .send(message, recipient):
                if let data = message.encoded() {
                    transport.send(data, to: recipient)
                }
            case let .player(directive):
                playback.apply(directive)
            case let .notice(text):
                playback.showNotice(text)
            }
        }
        refresh()
    }

    /// Copies what the panel shows out of the core, touching only what has changed so that
    /// views are not told about every tick.
    private func refresh() {
        let snapshot = playback.snapshot
        let host = core.hostID
        let shared = core.content?.content
        var list = [person(core.me, status: core.status(for: snapshot, now: now), host: host, shared: shared)]
        list += core.members.keys.sorted().map { person($0, status: core.members[$0]?.status, host: host, shared: shared) }
        assign(\.people, list)
        assign(\.content, shared)
        assign(\.isElsewhere, shared != nil && !core.isWatching(snapshot))
        assign(\.waitingFor, core.waitingFor.map { $0 == core.me ? "you" : core.displayName(of: $0) })
        assign(\.canControl, core.canControl)
        assign(\.everyoneControls, core.settings?.everyoneControls ?? true)
        assign(\.inVoice, core.inVoice)
        assign(\.isMuted, core.isMuted)
        if chat != core.chat {
            // What others did is also flashed over the picture, where eyes are.
            if core.chat.count > flashedEntries, let latest = core.chat.suffix(core.chat.count - flashedEntries).last(where: \.flashes) {
                playback.showNotice(latest.text)
            }
            flashedEntries = core.chat.count
            chat = core.chat
        }
    }

    private func person(_ id: MemberID, status: MemberStatus?, host: MemberID?, shared: PartyContent?) -> Person {
        let isOnSomethingElse = status?.activity == .away && status?.title != nil && status?.title != shared?.title
        return Person(
            id: id,
            name: core.displayName(of: id),
            isMe: id == core.me,
            isHost: id == host,
            activity: status?.activity ?? .away,
            otherTitle: isOnSomethingElse ? status?.title : nil,
            inVoice: status?.inVoice ?? false,
            isMuted: status?.isMuted ?? false
        )
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<PartySession, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}
