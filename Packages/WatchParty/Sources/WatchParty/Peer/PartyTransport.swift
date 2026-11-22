import Foundation

/// How things stand with the signalling server.
public enum SignalingState: Sendable, Equatable {
    case connecting
    /// In the room. People already connected stay connected even if this is lost again.
    case connected
    /// Lost, or not reached yet; trying again. `attempt` counts the tries in a row.
    case retrying(attempt: Int)
}

/// Why a party cannot go on.
public enum PartyFailure: Error, Sendable, Equatable {
    case roomFull
    /// The server refused for a reason this version does not know.
    case refused(String)

    public var userMessage: String {
        switch self {
        case .roomFull: "This party is full."
        case .refused: "The party server would not let this app in."
        }
    }
}

public enum TransportEvent: Sendable, Equatable {
    case signaling(SignalingState)
    /// A direct connection to someone is open and can carry messages.
    case peerConnected(MemberID)
    case peerDisconnected(MemberID)
    case data(Data, from: MemberID)
    case failed(PartyFailure)
}

/// Connects this app to the others in a party and carries what they say to each other.
public protocol PartyTransport: Sendable {
    /// What happens, in order. Ends when the transport has stopped.
    var events: AsyncStream<TransportEvent> { get }
    func start()
    /// To one person, or to everyone connected when `recipient` is `nil`.
    func send(_ data: Data, to recipient: MemberID?)
    /// Joins or leaves the voice chat, and silences this person's microphone in it.
    func setVoice(isEnabled: Bool, isMuted: Bool)
    func stop()
}
