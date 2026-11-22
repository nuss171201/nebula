import CryptoKit
import Foundation

/// Where a party's signalling server is: the small program that lets the apps in a party find
/// each other. It only introduces them; what they then say goes directly between them.
public struct PartyServer: Sendable, Hashable {
    /// The address as people see and share it, always ending in a slash.
    public let url: URL

    /// Accepts an `https` address with a host. Plain `http` is accepted for this machine (what
    /// checks and tests use) and for an address on the local network, where a party server run
    /// from the app itself is found (`PartyHostServer`): what passes through a server is sealed
    /// with the invitation's secret either way.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), let host = components.host, !host.isEmpty else { return nil }
        let scheme = components.scheme?.lowercased()
        let isNearby = Self.loopbackHosts.contains(host.lowercased()) || Self.isPrivateAddress(host)
        let isAllowed = scheme == "https" || (scheme == "http" && isNearby)
        guard isAllowed, components.user == nil, components.password == nil else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        guard let url = components.url else { return nil }
        self.url = url
    }

    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// Whether text is an IPv4 address that only exists on a local network (10.x, 172.16 to
    /// 172.31, 192.168.x, or the self-assigned 169.254.x): never a name, never a public address.
    public static func isPrivateAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, let first = parts[0], let second = parts[1], parts[2] != nil, parts[3] != nil else { return false }
        switch (first, second) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16 ... 31): return true
        default: return false
        }
    }

    /// Where the app connects: the same place, spoken to over a web socket.
    public var socketURL: URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path += "ws"
        return components.url ?? url
    }

    /// The same server as reached from the machine it runs on: by the loopback interface.
    public var socketURLOnThisMachine: URL {
        guard var components = URLComponents(url: socketURL, resolvingAgainstBaseURL: false) else { return socketURL }
        components.host = "127.0.0.1"
        return components.url ?? socketURL
    }

    /// Whether the server is on a local network (reached by a private address), which macOS
    /// lets an app onto only with the user's permission.
    public var isOnLocalNetwork: Bool {
        url.host.map(Self.isPrivateAddress) ?? false
    }

    /// Whether the server is on this machine.
    public var isLocal: Bool {
        url.host.map { Self.loopbackHosts.contains($0.lowercased()) } ?? false
    }
}

/// What gets a person into a party: the server to meet at, and a secret that only people with
/// the invitation know.
///
/// The secret never reaches the server. The room's name there is derived from it, and so is the
/// key that seals what the apps send each other through the server while they are being
/// introduced, so the server can neither read those messages nor put itself between two people.
public struct PartyInvite: Sendable, Equatable {
    public let server: PartyServer
    let secret: Data

    private static let secretLength = 16

    /// A new party at this server.
    public static func make(server: PartyServer) -> PartyInvite {
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0 ..< secretLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return PartyInvite(server: server, secret: secret)
    }

    init(server: PartyServer, secret: Data) {
        self.server = server
        self.secret = secret
    }

    /// Reads what someone pasted: an invitation link (`https://server/#code`), or the code alone
    /// when the app already knows which server to use.
    public init?(_ text: String, defaultServer: PartyServer? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let code: String
        let server: PartyServer?
        if let mark = trimmed.lastIndex(of: "#") {
            code = String(trimmed[trimmed.index(after: mark)...])
            server = PartyServer(String(trimmed[..<mark]))
        } else {
            code = trimmed
            server = defaultServer
        }
        guard let server, let secret = Self.decode(code), secret.count == Self.secretLength else { return nil }
        self.init(server: server, secret: secret)
    }

    /// The secret as text.
    public var code: String {
        secret.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// What to send to friends.
    public var link: String {
        server.url.absoluteString + "#" + code
    }

    private static func decode(_ code: String) -> Data? {
        guard code.count <= 64, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var base64 = code.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// The room's name at the server. Knowing it does not give the secret away.
    public var roomID: String {
        derive("room", length: 16).map { byte in
            let text = String(byte, radix: 16)
            return text.count == 1 ? "0" + text : text
        }.joined()
    }

    /// Seals and opens what travels through the server.
    var seal: SignalSeal {
        SignalSeal(key: SymmetricKey(data: derive("signal", length: 32)))
    }

    private func derive(_ purpose: String, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data("watch-party-v1".utf8),
            info: Data(purpose.utf8),
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

/// What two apps tell each other through the server in order to connect directly.
enum SignalPayload: Codable, Sendable, Equatable {
    /// A description of the connection one side proposes (`isOffer`) or accepts.
    case description(isOffer: Bool, sdp: String)
    /// A network path the other side can try.
    case candidate(sdp: String, mid: String?, lineIndex: Int32)
    /// The sender is leaving.
    case bye
}

/// Encrypts signalling with the party's key. A message is bound to who sent it and who it is
/// for, so the server cannot hand one person's message to another or replay it as someone else's.
struct SignalSeal: Sendable {
    let key: SymmetricKey

    func seal(_ payload: SignalPayload, from sender: MemberID, to recipient: MemberID) -> String? {
        guard let plain = try? JSONEncoder().encode(payload),
              let box = try? ChaChaPoly.seal(plain, using: key, authenticating: Self.binding(sender, recipient))
        else { return nil }
        return box.combined.base64EncodedString()
    }

    func open(_ text: String, from sender: MemberID, to recipient: MemberID) -> SignalPayload? {
        guard let combined = Data(base64Encoded: text),
              let box = try? ChaChaPoly.SealedBox(combined: combined),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: Self.binding(sender, recipient))
        else { return nil }
        return try? JSONDecoder().decode(SignalPayload.self, from: plain)
    }

    private static func binding(_ sender: MemberID, _ recipient: MemberID) -> Data {
        Data("\(sender.rawValue)>\(recipient.rawValue)".utf8)
    }
}
