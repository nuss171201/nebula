import Foundation

/// What the others say, and what follows from it.
public extension PartyCore {
    /// A direct connection to someone has opened: introduce ourselves and tell them where the party is.
    mutating func peerConnected(_ id: MemberID, now: TimeInterval) -> [Effect] {
        guard id != me, members[id] == nil else { return [] }
        members[id] = Member(nextPingAt: now)
        var effects: [Effect] = [.send(.hello(name: name, protocolVersion: PartyMessage.protocolVersion), to: id)]
        if let settings {
            effects.append(.send(.settings(settings), to: id))
        }
        if let content {
            effects.append(.send(.content(content), to: id))
        }
        if let playback {
            effects.append(.send(.playback(wire(for: playback, now: now)), to: id))
        }
        if let status = local.lastStatus {
            effects.append(.send(.status(status), to: id))
        }
        return effects
    }

    mutating func peerDisconnected(_ id: MemberID, now _: TimeInterval) -> [Effect] {
        guard let member = members.removeValue(forKey: id) else { return [] }
        if let name = member.name {
            addEvent("\(name) left.")
        }
        return []
    }

    mutating func receive(_ message: PartyMessage, from sender: MemberID, now: TimeInterval) -> [Effect] {
        guard members[sender] != nil else { return [] }
        var effects: [Effect] = []
        switch message {
        case let .hello(name, _):
            let cleaned = WireLimits.clean(name, limit: WireLimits.nameLength)
            let isNew = members[sender]?.name == nil
            members[sender]?.name = cleaned.isEmpty ? "Someone" : cleaned
            if isNew {
                addEvent("\(displayName(of: sender)) joined.")
            }
        case let .status(status):
            noteVoiceChange(of: sender, to: status)
            members[sender]?.status = status.sanitized()
        case let .ping(id, sentAt):
            effects.append(.send(.pong(id: id, sentAt: sentAt, receivedAt: now), to: sender))
        case let .pong(_, sentAt, remoteAt):
            members[sender]?.clock.addSample(sentAt: sentAt, remoteAt: remoteAt, receivedAt: now)
            if let waiting = members[sender]?.pendingPlayback {
                members[sender]?.pendingPlayback = nil
                accept(waiting, from: sender)
            }
        case let .playback(wire):
            if members[sender]?.clock.offset == nil {
                // Its position is on the sender's clock, which cannot be read yet.
                members[sender]?.pendingPlayback = wire
            } else {
                accept(wire, from: sender)
            }
        case let .content(shared):
            accept(shared)
        case let .settings(incoming):
            accept(incoming)
        case let .chat(wire):
            let text = WireLimits.clean(wire.text, limit: WireLimits.chatLength)
            let id = String(wire.id.prefix(64))
            guard !text.isEmpty, !chat.contains(where: { $0.id == id }) else { break }
            chat.append(ChatEntry(id: id, kind: .message(author: sender, name: displayName(of: sender)), text: text))
            trimChat()
        }
        return effects
    }

    private mutating func noteVoiceChange(of sender: MemberID, to status: MemberStatus) {
        let wasInVoice = members[sender]?.status?.inVoice ?? false
        if status.inVoice != wasInVoice {
            addEvent("\(displayName(of: sender)) \(status.inVoice ? "joined" : "left") the voice chat.")
        }
    }

    private mutating func accept(_ wire: PlaybackWire, from sender: MemberID) {
        let isNewer = playback.map { wire.version > $0.version } ?? true
        guard wire.isPlausible, isNewer else { return }
        let author = wire.version.author
        // Pausing to wait for someone, and resuming afterwards, is open to all; the rest is control.
        if wire.reason == .user || wire.reason == .content, !mayControl(author) {
            return
        }
        guard let offset = members[sender]?.clock.offset else { return }
        counter = max(counter, wire.version.counter)
        let previous = playback
        let state = SharedPlayback(
            position: wire.position,
            anchor: wire.sentAt - offset,
            isPaused: wire.isPaused,
            rate: wire.rate,
            holder: wire.isPaused ? wire.holder : nil,
            reason: wire.reason,
            version: wire.version
        )
        playback = state
        if let text = Self.describe(state, after: previous, by: displayName(of: author)) {
            addEvent(text)
        }
    }

    private mutating func accept(_ shared: SharedContent) {
        let isNewer = content.map { shared.version > $0.version } ?? true
        guard isNewer, mayControl(shared.version.author) else { return }
        counter = max(counter, shared.version.counter)
        let cleaned = SharedContent(content: shared.content?.sanitized(), version: shared.version)
        let isDifferent = cleaned.content?.key != content?.content?.key
        content = cleaned
        if isDifferent, let title = cleaned.content?.title {
            addEvent("\(displayName(of: shared.version.author)) started \(title).")
        }
    }

    private mutating func accept(_ incoming: RoomSettings) {
        if let settings {
            // Only the host changes the settings, and never to make someone else the host.
            guard incoming.version > settings.version, incoming.version.author == settings.hostID, incoming.hostID == settings.hostID else { return }
            if incoming.everyoneControls != settings.everyoneControls {
                addEvent(incoming.everyoneControls ? "Everyone can control playback now." : "Only the host controls playback now.")
            }
        }
        counter = max(counter, incoming.version.counter)
        settings = incoming
    }

    /// A change to where the party is, in words for the chat; `nil` for changes not worth a line.
    internal static func describe(_ state: SharedPlayback, after previous: SharedPlayback?, by name: String) -> String? {
        switch state.reason {
        case .wait:
            return "Waiting for \(name)…"
        case .resume, .content:
            return nil
        case .user:
            guard let previous else { return nil }
            if state.rate != previous.rate {
                return "\(name) set the speed to \(Self.format(rate: state.rate))."
            }
            if state.isPaused != previous.isPaused {
                return "\(name) \(state.isPaused ? "paused" : "resumed") at \(Self.format(time: state.position))."
            }
            return "\(name) jumped to \(Self.format(time: state.position))."
        }
    }

    internal static func format(time seconds: Double) -> String {
        let total = seconds.isFinite ? max(Int(seconds.rounded(.down)), 0) : 0
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        let tail = (secs < 10 ? "0" : "") + String(secs)
        return hours > 0 ? "\(hours):" + (minutes < 10 ? "0" : "") + "\(minutes):" + tail : "\(minutes):" + tail
    }

    internal static func format(rate: Double) -> String {
        let rounded = (rate * 100).rounded() / 100
        return (rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)) + "×"
    }
}
