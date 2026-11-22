import Foundation
import WatchParty

/// What the app was started with, as far as watch parties go. Like the player's and the stream
/// engine's starting configuration, a setting can only narrow it.
public struct PartyEnvironment: Sendable {
    /// The signalling server this build comes with; `nil` if none was configured. The user can
    /// name another in Settings, and an invitation link always carries its own.
    public var builtInServer: PartyServer?
    /// Keeps every party connection on this machine. For checks and tests, which must not make
    /// macOS ask about the network.
    public var staysOnThisMachine: Bool
    /// `false` keeps the microphone closed and the voice chat silent. For silent checks and tests.
    public var allowsVoice: Bool
    public var appName: String
    public var userAgent: String
    public var logSubsystem: String

    public init(
        builtInServer: PartyServer? = nil,
        staysOnThisMachine: Bool = true,
        allowsVoice: Bool = false,
        appName: String,
        userAgent: String,
        logSubsystem: String
    ) {
        self.builtInServer = builtInServer
        self.staysOnThisMachine = staysOnThisMachine
        self.allowsVoice = allowsVoice
        self.appName = appName
        self.userAgent = userAgent
        self.logSubsystem = logSubsystem
    }

    /// The Info.plist key the built-in server's address is read from (`PARTY_SERVER_URL` in
    /// `Config/Branding.xcconfig`).
    public static let serverInfoKey = "PartyServerURL"

    /// The built-in server named in an Info.plist, if it names a usable one.
    public static func builtInServer(infoDictionary: [String: Any]?) -> PartyServer? {
        (infoDictionary?[serverInfoKey] as? String).flatMap(PartyServer.init)
    }
}
