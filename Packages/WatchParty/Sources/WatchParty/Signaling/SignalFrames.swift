import Foundation

/// A server that helps two apps reach each other when neither can be reached directly (STUN), or
/// that passes their traffic along when nothing else works (TURN). Which ones to use is the
/// signalling server's to say.
public struct IceServer: Codable, Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    /// Only the kinds of address that are what they claim to be.
    var isUsable: Bool {
        !urls.isEmpty && urls.allSatisfy { url in
            ["stun:", "stuns:", "turn:", "turns:"].contains { url.lowercased().hasPrefix($0) } && url.count <= 300
        }
    }
}

/// What the app says to the signalling server.
package enum ClientFrame: Sendable, Equatable {
    case join(room: String, peer: MemberID)
    /// Pass this on to one person in the room. `data` is sealed; the server cannot read it.
    case relay(to: MemberID, data: String)
    case leave
}

/// What the signalling server says to the app.
package enum ServerFrame: Sendable, Equatable {
    /// In the room: who is already there, and which helper servers to use.
    case joined(peers: [MemberID], iceServers: [IceServer])
    case peerJoined(MemberID)
    case peerLeft(MemberID)
    case relayed(from: MemberID, data: String)
    /// The server refuses: `room-full`, `bad-request`, …
    case error(code: String)
}

private enum FrameKeys: String, CodingKey {
    case kind = "t", room, peer, data, peers, ice, code
}

extension ClientFrame: Codable {
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FrameKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "join":
            self = try .join(room: container.decode(String.self, forKey: .room), peer: container.decode(MemberID.self, forKey: .peer))
        case "to":
            self = try .relay(to: container.decode(MemberID.self, forKey: .peer), data: container.decode(String.self, forKey: .data))
        case "leave":
            self = .leave
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown frame")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FrameKeys.self)
        switch self {
        case let .join(room, peer):
            try container.encode("join", forKey: .kind)
            try container.encode(room, forKey: .room)
            try container.encode(peer, forKey: .peer)
        case let .relay(to, data):
            try container.encode("to", forKey: .kind)
            try container.encode(to, forKey: .peer)
            try container.encode(data, forKey: .data)
        case .leave:
            try container.encode("leave", forKey: .kind)
        }
    }
}

extension ServerFrame: Codable {
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FrameKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "joined":
            // An id that is not one is left out rather than spoiling the list.
            let names = try container.decode([String].self, forKey: .peers)
            let servers = try container.decodeIfPresent([IceServer].self, forKey: .ice) ?? []
            self = .joined(peers: names.compactMap(MemberID.init), iceServers: servers.filter(\.isUsable))
        case "peer-joined":
            self = try .peerJoined(container.decode(MemberID.self, forKey: .peer))
        case "peer-left":
            self = try .peerLeft(container.decode(MemberID.self, forKey: .peer))
        case "from":
            self = try .relayed(from: container.decode(MemberID.self, forKey: .peer), data: container.decode(String.self, forKey: .data))
        case "error":
            self = try .error(code: container.decodeIfPresent(String.self, forKey: .code) ?? "")
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown frame")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FrameKeys.self)
        switch self {
        case let .joined(peers, iceServers):
            try container.encode("joined", forKey: .kind)
            try container.encode(peers, forKey: .peers)
            try container.encode(iceServers, forKey: .ice)
        case let .peerJoined(peer):
            try container.encode("peer-joined", forKey: .kind)
            try container.encode(peer, forKey: .peer)
        case let .peerLeft(peer):
            try container.encode("peer-left", forKey: .kind)
            try container.encode(peer, forKey: .peer)
        case let .relayed(from, data):
            try container.encode("from", forKey: .kind)
            try container.encode(from, forKey: .peer)
            try container.encode(data, forKey: .data)
        case let .error(code):
            try container.encode("error", forKey: .kind)
            try container.encode(code, forKey: .code)
        }
    }
}
