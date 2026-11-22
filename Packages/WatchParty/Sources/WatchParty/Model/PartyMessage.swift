import Foundation

/// Where the party is, as one app tells another: the position is true at `sentAt` on the sender's clock.
public struct PlaybackWire: Codable, Sendable, Equatable {
    public var position: Double
    public var sentAt: TimeInterval
    public var isPaused: Bool
    public var rate: Double
    public var holder: MemberID?
    public var reason: SharedPlayback.Reason
    public var version: RegisterVersion

    /// Whether the numbers are ones a player can be sent to.
    var isPlausible: Bool {
        position.isFinite && position >= 0 && sentAt.isFinite && rate.isFinite && (0.25 ... 16).contains(rate)
    }
}

/// A line of chat on its way to the others.
public struct ChatWire: Codable, Sendable, Equatable {
    public var id: String
    public var text: String
}

/// Everything the apps in a party say to each other, over the direct connection between them.
public enum PartyMessage: Sendable, Equatable {
    /// The first thing said on a new connection.
    case hello(name: String, protocolVersion: Int)
    case status(MemberStatus)
    /// A clock reading to be sent straight back, for working out how far apart two clocks are.
    case ping(id: Int, sentAt: TimeInterval)
    case pong(id: Int, sentAt: TimeInterval, receivedAt: TimeInterval)
    case playback(PlaybackWire)
    case content(SharedContent)
    case settings(RoomSettings)
    case chat(ChatWire)
    /// Said after telling someone who has just connected everything there is to tell: they now
    /// know what the party is watching and where it is.
    case caughtUp

    /// The version of this conversation the app speaks.
    public static let protocolVersion = 1
}

extension PartyMessage: Codable {
    private enum Kind: String, Codable {
        case hello, status, ping, pong, playback, content, settings, chat
        case caughtUp = "caught-up"
    }

    private enum Keys: String, CodingKey {
        case kind = "t", body = "d"
    }

    private struct Hello: Codable {
        var name: String
        var version: Int
    }

    private struct Ping: Codable {
        var id: Int
        var at: TimeInterval
    }

    private struct Pong: Codable {
        var id: Int
        var at: TimeInterval
        var peerAt: TimeInterval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .hello:
            let body = try container.decode(Hello.self, forKey: .body)
            self = .hello(name: body.name, protocolVersion: body.version)
        case .status:
            self = try .status(container.decode(MemberStatus.self, forKey: .body))
        case .ping:
            let body = try container.decode(Ping.self, forKey: .body)
            self = .ping(id: body.id, sentAt: body.at)
        case .pong:
            let body = try container.decode(Pong.self, forKey: .body)
            self = .pong(id: body.id, sentAt: body.at, receivedAt: body.peerAt)
        case .playback:
            self = try .playback(container.decode(PlaybackWire.self, forKey: .body))
        case .content:
            self = try .content(container.decode(SharedContent.self, forKey: .body))
        case .settings:
            self = try .settings(container.decode(RoomSettings.self, forKey: .body))
        case .chat:
            self = try .chat(container.decode(ChatWire.self, forKey: .body))
        case .caughtUp:
            self = .caughtUp
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .hello(name, version):
            try container.encode(Kind.hello, forKey: .kind)
            try container.encode(Hello(name: name, version: version), forKey: .body)
        case let .status(status):
            try container.encode(Kind.status, forKey: .kind)
            try container.encode(status, forKey: .body)
        case let .ping(id, sentAt):
            try container.encode(Kind.ping, forKey: .kind)
            try container.encode(Ping(id: id, at: sentAt), forKey: .body)
        case let .pong(id, sentAt, receivedAt):
            try container.encode(Kind.pong, forKey: .kind)
            try container.encode(Pong(id: id, at: sentAt, peerAt: receivedAt), forKey: .body)
        case let .playback(wire):
            try container.encode(Kind.playback, forKey: .kind)
            try container.encode(wire, forKey: .body)
        case let .content(content):
            try container.encode(Kind.content, forKey: .kind)
            try container.encode(content, forKey: .body)
        case let .settings(settings):
            try container.encode(Kind.settings, forKey: .kind)
            try container.encode(settings, forKey: .body)
        case let .chat(chat):
            try container.encode(Kind.chat, forKey: .kind)
            try container.encode(chat, forKey: .body)
        case .caughtUp:
            try container.encode(Kind.caughtUp, forKey: .kind)
        }
    }

    /// The message as it travels. `nil` only if a number in it cannot be written as JSON.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Reads what another app sent. `nil` for anything that is not a message this version knows,
    /// which is then simply not acted on.
    public static func decode(_ data: Data) -> PartyMessage? {
        // Nothing the apps say to each other is anywhere near this long.
        guard data.count <= 32 * 1024 else { return nil }
        return try? JSONDecoder().decode(PartyMessage.self, from: data)
    }
}
