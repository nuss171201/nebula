import Foundation
@preconcurrency import WebRTC

/// Making, negotiating and dropping the connection to each person. Everything here runs on the mesh's queue.
extension WebRTCTransport {
    static let channelLabel = "party"
    /// How many people a party holds. Everyone is connected to everyone, which does not scale far.
    public static let roomLimit = 8

    func makeLink(to peer: MemberID) -> PeerLink {
        let rtc = RTCConfiguration()
        rtc.sdpSemantics = .unifiedPlan
        rtc.bundlePolicy = .maxBundle
        rtc.continualGatheringPolicy = .gatherContinually
        // Lets the polite side drop its own proposal when both propose at once.
        rtc.enableImplicitRollback = true
        rtc.iceServers = configuration.staysOnThisMachine ? [] : iceServers.map { server in
            RTCIceServer(urlStrings: server.urls, username: server.username, credential: server.credential)
        }
        let link = PeerLink(id: peer, isPolite: configuration.me > peer) { [weak self] id, event in
            guard let self else { return }
            queue.async {
                self.handle(event, from: id)
            }
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let connection = factory.peerConnection(with: rtc, constraints: constraints, delegate: link)
        link.connection = connection
        // The same numbered channel on both sides, so neither has to announce it to the other.
        let channelSettings = RTCDataChannelConfiguration()
        channelSettings.isNegotiated = true
        channelSettings.channelId = 0
        channelSettings.isOrdered = true
        link.channel = connection?.dataChannel(forLabel: Self.channelLabel, configuration: channelSettings)
        link.channel?.delegate = link
        links[peer] = link
        _ = updateVoice(on: link)
        return link
    }

    func drop(_ link: PeerLink, announce: Bool) {
        guard links[link.id] === link else { return }
        links[link.id] = nil
        let wasOpen = link.isOpen
        link.isOpen = false
        link.close()
        if wasOpen, announce {
            emit(.peerDisconnected(link.id))
        }
    }

    // MARK: - Agreeing on the connection

    /// Proposes the connection's current shape to the other side, if something has changed and
    /// no exchange is in progress.
    func negotiateIfNeeded(_ link: PeerLink) {
        guard let connection = link.connection, links[link.id] === link else { return }
        let isIdle = !link.isMakingOffer && connection.signalingState == .stable
        guard link.needsNegotiation, isIdle else { return }
        link.needsNegotiation = false
        link.isMakingOffer = true
        connection.setLocalDescriptionWithCompletionHandler { [self, link] error in
            queue.async { [self] in
                guard links[link.id] === link else { return }
                link.isMakingOffer = false
                if let error {
                    logger.error("could not make an offer: \(error.localizedDescription, privacy: .public)")
                    return
                }
                if let description = connection.localDescription, description.type == .offer {
                    relay(.description(isOffer: true, sdp: description.sdp), to: link.id)
                }
            }
        }
    }

    func receive(_ payload: SignalPayload, from sender: MemberID) {
        switch payload {
        case let .description(isOffer, sdp):
            // Someone we have no connection to proposes one: they have just arrived (or come back).
            let link = links[sender] ?? (isOffer ? makeLink(to: sender) : nil)
            if let link {
                apply(RTCSessionDescription(type: isOffer ? .offer : .answer, sdp: sdp), from: link)
            }
        case let .candidate(sdp, mid, lineIndex):
            guard let link = links[sender], let connection = link.connection else { return }
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: lineIndex, sdpMid: mid)
            if connection.remoteDescription == nil {
                link.waitingCandidates.append(candidate)
            } else {
                add(candidate, to: link)
            }
        case .bye:
            if let link = links[sender] {
                drop(link, announce: true)
            }
        }
    }

    private func apply(_ description: RTCSessionDescription, from link: PeerLink) {
        guard let connection = link.connection else { return }
        let isOffer = description.type == .offer
        let collides = isOffer && (link.isMakingOffer || connection.signalingState != .stable)
        link.isIgnoringOffer = collides && !link.isPolite
        guard !link.isIgnoringOffer else { return }
        if collides {
            // Our own proposal is given up for theirs; whatever it was for is proposed again afterwards.
            link.needsNegotiation = true
        }
        connection.setRemoteDescription(description) { [self, link] error in
            queue.async { [self] in
                guard links[link.id] === link else { return }
                if let error {
                    logger.error("could not apply a description: \(error.localizedDescription, privacy: .public)")
                    return
                }
                let waiting = link.waitingCandidates
                link.waitingCandidates = []
                waiting.forEach { self.add($0, to: link) }
                if isOffer {
                    answer(link)
                } else {
                    negotiateIfNeeded(link)
                }
            }
        }
    }

    private func answer(_ link: PeerLink) {
        guard let connection = link.connection else { return }
        // The answer says whether this side is in the voice chat.
        _ = updateVoice(on: link)
        link.needsNegotiation = false
        connection.setLocalDescriptionWithCompletionHandler { [self, link] error in
            queue.async { [self] in
                guard links[link.id] === link else { return }
                if let error {
                    logger.error("could not answer: \(error.localizedDescription, privacy: .public)")
                    return
                }
                if let description = connection.localDescription, description.type == .answer {
                    relay(.description(isOffer: false, sdp: description.sdp), to: link.id)
                }
                negotiateIfNeeded(link)
            }
        }
    }

    private func add(_ candidate: RTCIceCandidate, to link: PeerLink) {
        link.connection?.add(candidate) { [logger, link] error in
            guard let error, !link.isIgnoringOffer else { return }
            logger.notice("a network path was not accepted: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - What a connection reports

    func handle(_ event: LinkEvent, from id: MemberID) {
        guard let link = links[id], !isStopped else { return }
        switch event {
        case let .localCandidate(candidate):
            relay(.candidate(sdp: candidate.sdp, mid: candidate.sdpMid, lineIndex: candidate.sdpMLineIndex), to: id)
        case let .message(data):
            emit(.data(data, from: id))
        case let .channelState(state):
            if state == .open, !link.isOpen {
                link.isOpen = true
                reconnectAttempts[id] = nil
                emit(.peerConnected(id))
            } else if state == .closed {
                drop(link, announce: true)
            }
        case let .connectionState(state):
            guard state == .failed || state == .closed else { return }
            drop(link, announce: true)
            if state == .failed {
                reconnectLater(to: id)
            }
        }
    }

    /// After a connection has failed while the person is still in the room, one side tries again
    /// (the same side every time, so that both do not).
    private func reconnectLater(to peer: MemberID) {
        let attempts = reconnectAttempts[peer, default: 0]
        guard configuration.me > peer, attempts < 3 else { return }
        reconnectAttempts[peer] = attempts + 1
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            guard !isStopped, roster.contains(peer), links[peer] == nil, signaling != nil else { return }
            let link = makeLink(to: peer)
            link.needsNegotiation = true
            negotiateIfNeeded(link)
        }
    }
}
