import Foundation

/// The whole logic of being in a party, with nothing attached: it is told what happens (a message
/// arrives, the person here pauses, a quarter of a second passes) with the time it happens at,
/// and answers with what to do (send this, pause the player, seek). Everything that makes players
/// stay together is decided here, so it can be tested with made-up clocks and players.
public struct PartyCore: Sendable {
    public enum Effect: Sendable, Equatable {
        /// To one person, or to everyone when `to` is `nil`.
        case send(PartyMessage, to: MemberID?)
        case player(PlayerDirective)
        /// A short message for the person at this Mac.
        case notice(String)
    }

    /// Someone else in the party.
    public struct Member: Sendable, Equatable {
        public internal(set) var name: String?
        public internal(set) var status: MemberStatus?
        public internal(set) var clock = ClockSync()
        var nextPingAt: TimeInterval
        var pingsSent = 0
        /// A position that arrived before the two clocks had been compared.
        var pendingPlayback: PlaybackWire?
    }

    /// A line in the party's chat: something someone wrote, or something that happened.
    public struct ChatEntry: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case message(author: MemberID, name: String)
            case event
        }

        public var id: String
        public var kind: Kind
        public var text: String
        /// Whether to flash it over the picture as it happens: true for what others did, not for
        /// what the person here just did themselves.
        public var flashes = false
    }

    /// What is remembered about this Mac's own player between ticks.
    struct LocalState: Sendable, Equatable {
        var contentKey: String?
        /// Whether this player has been in step with the party for the video it has open. Until
        /// then its jumps and pauses are its own business (resuming where it was left, say).
        var hasSynced = false
        var stallSince: TimeInterval?
        var lastSeekAt: TimeInterval?
        var awaitsSeekLanding = false
        /// Whether a jump that landed wide has already been followed by a second, better-aimed one.
        var hasRetriedJump = false
        /// How far ahead of the party a jump aims, to make up for the time the jump takes.
        var seekLead = 0.25
        var rateAdjustment = 1.0
        var lastStatus: MemberStatus?
        var lastStatusAt: TimeInterval?
    }

    public let me: MemberID
    public private(set) var name: String
    public internal(set) var members: [MemberID: Member] = [:]
    public internal(set) var settings: RoomSettings?
    public internal(set) var playback: SharedPlayback?
    public internal(set) var content: SharedContent?
    public internal(set) var chat: [ChatEntry] = []
    /// Whether this person is in the voice chat, and silenced there.
    public var inVoice = false
    public var isMuted = false

    var local = LocalState()
    /// The highest version counter seen on any shared value.
    var counter = 0
    var eventCount = 0
    var pingCount = 0

    /// - Parameter isHost: Whether this person started the party. The host's app decides who may control playback.
    public init(me: MemberID, name: String, isHost: Bool) {
        self.me = me
        self.name = WireLimits.clean(name, limit: WireLimits.nameLength)
        if isHost {
            settings = RoomSettings(hostID: me, everyoneControls: true, version: RegisterVersion(counter: 1, author: me))
            counter = 1
        }
    }

    // MARK: - Who is who

    /// The host, or whoever stands in for a host who has left.
    public var hostID: MemberID? {
        guard let settings else { return nil }
        if settings.hostID == me || members[settings.hostID] != nil {
            return settings.hostID
        }
        return everyone.min()
    }

    var everyone: [MemberID] {
        members.keys + [me]
    }

    /// Whether this person may pause, seek and choose what is watched.
    public var canControl: Bool {
        mayControl(me)
    }

    func mayControl(_ id: MemberID) -> Bool {
        // Before the host's settings have arrived there is nothing to refuse anyone by.
        guard let settings else { return id != me }
        return settings.everyoneControls || id == hostID
    }

    public func displayName(of id: MemberID) -> String {
        if id == me {
            return name
        }
        return members[id]?.name ?? "Someone"
    }

    /// Who the party is paused for, if it paused by itself.
    public var waitingFor: MemberID? {
        guard let playback, playback.isPaused else { return nil }
        return playback.holder
    }

    // MARK: - Shared values

    mutating func nextVersion() -> RegisterVersion {
        counter += 1
        return RegisterVersion(counter: counter, author: me)
    }

    /// Changes where the party is and tells everyone.
    mutating func publishPlayback(
        position: Double,
        isPaused: Bool,
        rate: Double? = nil,
        holder: MemberID? = nil,
        reason: SharedPlayback.Reason,
        now: TimeInterval,
        into effects: inout [Effect]
    ) {
        let state = SharedPlayback(
            position: max(position, 0),
            anchor: now,
            isPaused: isPaused,
            rate: rate ?? playback?.rate ?? 1,
            holder: isPaused ? holder : nil,
            reason: reason,
            version: nextVersion()
        )
        playback = state
        effects.append(.send(.playback(wire(for: state, now: now)), to: nil))
    }

    /// Where the party is right now, in the form another app can place on its own clock.
    func wire(for state: SharedPlayback, now: TimeInterval) -> PlaybackWire {
        PlaybackWire(
            position: max(state.position(at: now), 0),
            sentAt: now,
            isPaused: state.isPaused,
            rate: state.rate,
            holder: state.holder,
            reason: state.reason,
            version: state.version
        )
    }

    mutating func addEvent(_ text: String, flashes: Bool = true) {
        eventCount += 1
        chat.append(ChatEntry(id: "event-\(eventCount)", kind: .event, text: text, flashes: flashes))
        trimChat()
    }

    mutating func trimChat() {
        if chat.count > 500 {
            chat.removeFirst(chat.count - 500)
        }
    }

    // MARK: - What the person here does

    /// Lets the host decide whether everyone or only they control playback.
    public mutating func setEveryoneControls(_ everyoneControls: Bool) -> [Effect] {
        guard var settings, settings.hostID == me, settings.everyoneControls != everyoneControls else { return [] }
        settings.everyoneControls = everyoneControls
        settings.version = nextVersion()
        self.settings = settings
        addEvent(everyoneControls ? "Everyone can control playback now." : "Only the host controls playback now.")
        return [.send(.settings(settings), to: nil)]
    }

    public mutating func sendChat(_ text: String) -> [Effect] {
        let cleaned = WireLimits.clean(text, limit: WireLimits.chatLength)
        guard !cleaned.isEmpty else { return [] }
        let wire = ChatWire(id: UUID().uuidString.lowercased(), text: cleaned)
        chat.append(ChatEntry(id: wire.id, kind: .message(author: me, name: name), text: cleaned))
        trimChat()
        return [.send(.chat(wire), to: nil)]
    }

    /// Says in the chat that voice was joined or left; the status sent with the next tick tells the others' apps.
    public mutating func setVoice(inVoice: Bool, isMuted: Bool) {
        if inVoice != self.inVoice {
            addEvent(inVoice ? "You joined the voice chat." : "You left the voice chat.", flashes: false)
        }
        self.inVoice = inVoice
        self.isMuted = isMuted
    }
}
