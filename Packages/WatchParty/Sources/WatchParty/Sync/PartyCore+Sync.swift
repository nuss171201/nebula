import Foundation

/// Keeping this Mac's player where the party is, and the party where its people are.
public extension PartyCore {
    /// Whether this player has the party's video open, far enough to be played.
    func isWatching(_ snapshot: PlaybackSnapshot) -> Bool {
        guard snapshot.hasMedia, let mine = snapshot.content else { return false }
        guard let shared = content?.content else { return true }
        return shared.matches(mine)
    }

    /// Called a few times a second with what the player is doing.
    mutating func tick(_ snapshot: PlaybackSnapshot, now: TimeInterval) -> [Effect] {
        var effects: [Effect] = []
        noteContent(snapshot, now: now, into: &effects)
        follow(snapshot, now: now, into: &effects)
        manageHold(snapshot, now: now, into: &effects)
        reportStatus(snapshot, now: now, into: &effects)
        sendPings(now: now, into: &effects)
        return effects
    }

    /// The person here paused, resumed, jumped or changed speed themselves.
    mutating func localIntent(_ intent: LocalIntent, snapshot: PlaybackSnapshot, now: TimeInterval) -> [Effect] {
        // A player that is not in step yet is finding its own way there; that is not a command.
        guard isWatching(snapshot), local.hasSynced else { return [] }
        guard canControl else {
            // The next tick puts the player back where the party is.
            return [.notice("Only the host controls playback in this party.")]
        }
        var effects: [Effect] = []
        let previous = playback
        switch intent {
        case let .setPaused(isPaused):
            guard isPaused != previous?.isPaused || previous?.holder != nil else { return [] }
            publishPlayback(position: snapshot.position, isPaused: isPaused, reason: .user, now: now, into: &effects)
        case let .seeked(position):
            // A jump while the party waits for someone keeps it waiting, now for whoever jumped.
            let isPaused = previous?.isPaused ?? snapshot.isPaused
            let holder = previous?.holder == nil ? nil : me
            publishPlayback(position: position, isPaused: isPaused, holder: holder, reason: .user, now: now, into: &effects)
            local.lastSeekAt = now
        case let .rate(rate):
            guard rate != previous?.rate else { return [] }
            let position = previous?.position(at: now) ?? snapshot.position
            publishPlayback(
                position: position, isPaused: previous?.isPaused ?? snapshot.isPaused, rate: rate,
                holder: previous?.holder, reason: .user, now: now, into: &effects
            )
        }
        if let playback, let text = Self.describe(playback, after: previous, by: "You") {
            addEvent(text, flashes: false)
        }
        return effects
    }

    // MARK: - What is being watched

    /// Decides whether what this player has open becomes what the party watches. It does when
    /// the party has nothing on yet, and when someone who was watching with the party moves on to
    /// another video; in both cases only for someone who controls the party and knows how it stands.
    /// Anyone else has simply gone their own way, or has just opened what the party is watching.
    private mutating func noteContent(_ snapshot: PlaybackSnapshot, now: TimeInterval, into effects: inout [Effect]) {
        let key = snapshot.content?.key
        let hasChanged = key != local.contentKey
        let wasInStep = local.hasSynced
        if hasChanged {
            local.contentKey = key
            local.hasSynced = false
            local.stallSince = nil
            local.awaitsSeekLanding = false
            local.lastSeekAt = nil
            setAdjustment(1, into: &effects)
        }

        guard let mine = snapshot.content, canControl, isInformed else { return }
        let shared = content?.content
        let movesThePartyOn = hasChanged && wasInStep && shared?.key != mine.key
        guard shared == nil || movesThePartyOn else { return }
        let published = SharedContent(content: mine.sanitized(), version: nextVersion())
        content = published
        effects.append(.send(.content(published), to: nil))
        addEvent("You started \(mine.title).", flashes: false)
        if snapshot.hasMedia {
            // Already playing: the party is wherever this player is.
            publishPlayback(position: snapshot.position, isPaused: snapshot.isPaused, rate: snapshot.rate, reason: .content, now: now, into: &effects)
        } else {
            // Still opening: the party waits at the start until it has.
            publishPlayback(position: 0, isPaused: true, rate: snapshot.rate, holder: me, reason: .content, now: now, into: &effects)
        }
        local.hasSynced = true
    }

    // MARK: - Following the party

    private mutating func follow(_ snapshot: PlaybackSnapshot, now: TimeInterval, into effects: inout [Effect]) {
        // A jump of the person's own that is still on its way is about to become where the party
        // is; pulling the player back to where the party was would undo it.
        guard let target = playback, isWatching(snapshot), !snapshot.hasPendingJump else { return }
        if abs(snapshot.rate - target.rate) > 0.001 {
            effects.append(.player(.setRate(target.rate)))
        }
        let expected = min(target.position(at: now), snapshot.duration ?? .greatestFiniteMagnitude)
        let delta = snapshot.position - expected
        if target.isPaused {
            followPaused(snapshot, target: target, delta: delta, now: now, into: &effects)
        } else {
            followPlaying(snapshot, expected: expected, delta: delta, now: now, into: &effects)
        }
    }

    private mutating func followPaused(
        _ snapshot: PlaybackSnapshot, target: SharedPlayback, delta: Double, now: TimeInterval, into effects: inout [Effect]
    ) {
        setAdjustment(1, into: &effects)
        if !snapshot.isPaused, !snapshot.hasEnded {
            effects.append(.player(.setPaused(true)))
        }
        if abs(delta) <= SyncTuning.pausedTolerance {
            local.hasSynced = true
            local.awaitsSeekLanding = false
        } else if !snapshot.isStalled, mayJump(now) {
            jump(to: target.position, now: now, into: &effects)
        }
    }

    private mutating func followPlaying(
        _ snapshot: PlaybackSnapshot, expected: Double, delta: Double, now: TimeInterval, into effects: inout [Effect]
    ) {
        if snapshot.hasEnded {
            // Sitting on the last frame is where the party is too, unless it has gone back.
            let partyIsAtEnd = snapshot.duration.map { expected >= $0 - 0.75 } ?? true
            if !partyIsAtEnd, mayJump(now) {
                jump(to: expected, now: now, into: &effects)
            }
            return
        }
        if snapshot.isPaused {
            if abs(delta) > SyncTuning.jumpThreshold, !snapshot.isStalled, mayJump(now) {
                jump(to: expected + local.seekLead, now: now, into: &effects)
            }
            effects.append(.player(.setPaused(false)))
            return
        }
        guard !snapshot.isStalled else { return }
        if retriesAfterLanding(delta: delta, expected: expected, now: now, into: &effects) {
            return
        }
        if abs(delta) > SyncTuning.jumpThreshold {
            if mayJump(now) {
                jump(to: expected + local.seekLead, now: now, into: &effects)
            }
            return
        }
        local.hasSynced = true
        setAdjustment(SyncTuning.rateAdjustment(forGap: delta, current: local.rateAdjustment), into: &effects)
        if local.rateAdjustment == 1 {
            local.hasRetriedJump = false
        }
    }

    /// The first look after a jump has landed shows how long jumps take here, and the next one
    /// aims that much further ahead. If this one landed well off, it is repeated at once with what
    /// was just learnt, rather than followed by many seconds of playing fast. Returns whether it was.
    private mutating func retriesAfterLanding(delta: Double, expected: Double, now: TimeInterval, into effects: inout [Effect]) -> Bool {
        guard local.awaitsSeekLanding, let lastSeekAt = local.lastSeekAt, now - lastSeekAt >= 0.2 else { return false }
        guard abs(delta) < 3 else {
            // Nowhere near yet: the player has not got round to the jump. Keep waiting for it,
            // until it is time to conclude that it went wrong and to jump again.
            if now - lastSeekAt >= SyncTuning.jumpCooldown {
                local.awaitsSeekLanding = false
            }
            return false
        }
        local.awaitsSeekLanding = false
        local.seekLead = min(max(local.seekLead - delta, 0.1), 6)
        guard abs(delta) > SyncTuning.retryThreshold, !local.hasRetriedJump else { return false }
        local.hasRetriedJump = true
        jump(to: expected + local.seekLead, now: now, into: &effects)
        return true
    }

    private func mayJump(_ now: TimeInterval) -> Bool {
        local.lastSeekAt.map { now - $0 >= SyncTuning.jumpCooldown } ?? true
    }

    private mutating func jump(to position: Double, now: TimeInterval, into effects: inout [Effect]) {
        local.lastSeekAt = now
        local.awaitsSeekLanding = true
        effects.append(.player(.seek(to: max(position, 0))))
    }

    private mutating func setAdjustment(_ value: Double, into effects: inout [Effect]) {
        guard value != local.rateAdjustment else { return }
        local.rateAdjustment = value
        effects.append(.player(.adjustRate(value)))
    }

    // MARK: - Waiting for each other

    /// Pauses the party when this player, having been in step, stalls; and lets it go on again
    /// once nobody is stalled, if this app is the one that paused it (or stands in for one that left).
    private mutating func manageHold(_ snapshot: PlaybackSnapshot, now: TimeInterval, into effects: inout [Effect]) {
        guard let target = playback else { return }
        let isStalled = isWatching(snapshot) && snapshot.isStalled
        if isStalled {
            local.stallSince = local.stallSince ?? now
        } else {
            local.stallSince = nil
        }

        if !target.isPaused {
            if local.hasSynced, let since = local.stallSince, now - since >= SyncTuning.stallBeforeHold {
                publishPlayback(position: target.position(at: now), isPaused: true, holder: me, reason: .wait, now: now, into: &effects)
                addEvent("Waiting for you…")
            }
            return
        }
        guard let holder = target.holder, now - target.anchor >= SyncTuning.minimumHold else { return }
        let isMine = holder == me || (members[holder] == nil && me == everyone.min())
        guard isMine else { return }
        // Nothing open any more is no reason to keep the others waiting; a file still opening is.
        let amReady = snapshot.content == nil || (snapshot.hasMedia && !snapshot.isStalled)
        let othersReady = members.values.allSatisfy { $0.status?.activity != .stalled }
        if amReady, othersReady {
            publishPlayback(position: target.position, isPaused: false, reason: .resume, now: now, into: &effects)
        }
    }

    // MARK: - Telling the others

    func status(for snapshot: PlaybackSnapshot, now: TimeInterval) -> MemberStatus {
        let activity: MemberStatus.Activity
        if !isWatching(snapshot) {
            // Opening what the party watches counts as on the way; anything else as elsewhere.
            let isOpening = !snapshot.hasMedia && snapshot.content.map { mine in content?.content.map { $0.matches(mine) } ?? true } == true
            activity = isOpening ? .catchingUp : .away
        } else if let since = local.stallSince, now - since >= SyncTuning.stallBeforeReport, local.hasSynced {
            activity = .stalled
        } else {
            activity = local.hasSynced ? .ready : .catchingUp
        }
        return MemberStatus(
            activity: activity,
            title: snapshot.content?.title,
            position: snapshot.hasMedia ? snapshot.position : nil,
            inVoice: inVoice,
            isMuted: isMuted
        )
    }

    private mutating func reportStatus(_ snapshot: PlaybackSnapshot, now: TimeInterval, into effects: inout [Effect]) {
        let current = status(for: snapshot, now: now)
        let isDue = local.lastStatusAt.map { now - $0 >= SyncTuning.statusInterval } ?? true
        let isNews = local.lastStatus.map { current.differsBeyondPosition(from: $0) } ?? true
        guard isDue || isNews else { return }
        local.lastStatus = current
        local.lastStatusAt = now
        if !members.isEmpty {
            effects.append(.send(.status(current), to: nil))
        }
    }

    /// Clocks are compared in a quick burst when someone connects, then every few seconds.
    private mutating func sendPings(now: TimeInterval, into effects: inout [Effect]) {
        for id in members.keys.sorted() {
            guard var member = members[id], now >= member.nextPingAt else { continue }
            pingCount += 1
            member.pingsSent += 1
            member.nextPingAt = now + (member.pingsSent < 4 ? 0.25 : 5)
            members[id] = member
            effects.append(.send(.ping(id: pingCount, sentAt: now), to: id))
        }
    }
}
