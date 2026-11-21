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
