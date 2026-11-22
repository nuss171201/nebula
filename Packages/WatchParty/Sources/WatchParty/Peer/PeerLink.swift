import Foundation
@preconcurrency import WebRTC

/// What a peer connection and its channel report, for the mesh to act on.
enum LinkEvent {
    case localCandidate(RTCIceCandidate)
    case connectionState(RTCPeerConnectionState)
    case channelState(RTCDataChannelState)
    case message(Data)
}

/// The direct connection to one person: the peer connection, the channel that carries the
/// party's messages, and where the two sides are in agreeing on the connection's shape.
///
/// Used on the mesh's queue only. WebRTC calls its delegates on a thread of its own; they do
/// nothing but pass what happened to `report`.
final class PeerLink: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    let id: MemberID
    /// Assigned once, right after the connection is made (the connection wants its delegate first).
    var connection: RTCPeerConnection?
    var channel: RTCDataChannel?
    /// When both sides propose at once, the polite one gives way.
    let isPolite: Bool
    var isMakingOffer = false
    var isIgnoringOffer = false
    var needsNegotiation = false
    /// Paths the other side sent before its description had been applied.
    var waitingCandidates: [RTCIceCandidate] = []
    /// Whether the channel is open, which is when the person counts as connected.
    var isOpen = false
    private let report: @Sendable (MemberID, LinkEvent) -> Void

    init(id: MemberID, isPolite: Bool, report: @escaping @Sendable (MemberID, LinkEvent) -> Void) {
        self.id = id
        self.isPolite = isPolite
        self.report = report
    }

    func close() {
        channel?.delegate = nil
        channel?.close()
        connection?.delegate = nil
        connection?.close()
    }

    // MARK: - RTCPeerConnectionDelegate

    func peerConnection(_: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        report(id, .localCandidate(candidate))
    }

    func peerConnection(_: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        report(id, .connectionState(newState))
    }

    func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    // Negotiation is started by the mesh when it changes something, not by this callback.
    func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceConnectionState) {}
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceGatheringState) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
    // The channel is agreed on by number, so the other side never opens one towards us.
    func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}

    // MARK: - RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        report(id, .channelState(dataChannel.readyState))
    }

    func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        report(id, .message(buffer.data))
    }
}
