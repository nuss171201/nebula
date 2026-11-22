import Foundation
@preconcurrency import WebRTC

/// Voice: a microphone track sent to everyone who is also in the voice chat. Runs on the mesh's queue.
///
/// The microphone is opened by WebRTC only while some connection is actually sending sound, so
/// nothing here touches it until the person joins the voice chat and someone else is in it.
extension WebRTCTransport {
    func applyVoice(isEnabled: Bool, isMuted: Bool) {
        isVoiceEnabled = isEnabled
        self.isMuted = isMuted
        if isEnabled, microphone == nil {
            // Echo cancellation, noise suppression and automatic gain are WebRTC's defaults for a microphone.
            let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            microphone = factory.audioTrack(with: source, trackId: "microphone")
        }
        microphone?.isEnabled = !isMuted
        for link in links.values where updateVoice(on: link) {
            link.needsNegotiation = true
            negotiateIfNeeded(link)
        }
        if !isEnabled {
            microphone = nil
        }
    }

    /// Makes a connection's audio match whether this person is in the voice chat: sending and
    /// receiving if so, neither if not. Returns whether anything changed.
    func updateVoice(on link: PeerLink) -> Bool {
        guard let connection = link.connection else { return false }
        let existing = connection.transceivers.first { $0.mediaType == .audio && !$0.isStopped }
        guard isVoiceEnabled, let microphone else {
            guard let existing, existing.direction != .inactive else { return false }
            existing.sender.track = nil
            var error: NSError?
            existing.setDirection(.inactive, error: &error)
            return true
        }
        if let existing {
            guard existing.direction != .sendRecv || existing.sender.track == nil else { return false }
            existing.sender.track = microphone
            var error: NSError?
            existing.setDirection(.sendRecv, error: &error)
            return true
        }
        let settings = RTCRtpTransceiverInit()
        settings.direction = .sendRecv
        settings.streamIds = ["voice"]
        return connection.addTransceiver(with: microphone, init: settings) != nil
    }
}

/// How the audio on the connection to one person stands, for checks.
package enum VoiceLinkState: Sendable, Equatable {
    /// Audio has never been part of this connection.
    case absent
    /// Agreed on, and flowing in neither direction.
    case inactive
    /// Agreed on; this side may send, receive or both.
    case flowing
    /// Asked for on this side, not yet agreed with the other.
    case pending
}

package extension WebRTCTransport {
    /// The state of the audio on every connection, read on the mesh's queue.
    func voiceLinkStates() async -> [MemberID: VoiceLinkState] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var states: [MemberID: VoiceLinkState] = [:]
                for link in links.values {
                    guard let transceiver = link.connection?.transceivers.first(where: { $0.mediaType == .audio }) else {
                        states[link.id] = .absent
                        continue
                    }
                    var direction = RTCRtpTransceiverDirection.inactive
                    if !transceiver.currentDirection(&direction) {
                        states[link.id] = .pending
                    } else {
                        states[link.id] = direction == .inactive ? .inactive : .flowing
                    }
                }
                continuation.resume(returning: states)
            }
        }
    }

    /// Proposes every connection's shape to the other side again, as a change to the voice chat
    /// does. For checking what happens when both sides do so at once.
    func renegotiateAll() {
        queue.async { [self] in
            for link in links.values {
                link.needsNegotiation = true
                negotiateIfNeeded(link)
            }
        }
    }

    /// Whether every connection has finished agreeing on its shape.
    func isSettled() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: links.values.allSatisfy { link in
                    !link.needsNegotiation && !link.isMakingOffer && link.connection?.signalingState == .stable
                })
            }
        }
    }
}
