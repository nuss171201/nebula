import Foundation
import Observation
import os
import WatchParty

/// The party server this Mac runs itself, when the user has switched it on in Settings: what
/// lets people on the same network start a party without anyone hosting anything.
@MainActor
@Observable
public final class PartyHost {
    /// The running server's address, as the others reach it; `nil` while it is off.
    public private(set) var server: PartyServer?
    /// Why it could not be started, in words.
    public private(set) var problem: String?
    public private(set) var isStarting = false

    @ObservationIgnored private var running: PartyHostServer?
    @ObservationIgnored private let reach: PartyHostServer.Reach
    @ObservationIgnored private let logger: Logger
    /// The switch as it was last asked to be, so that a start overtaken by a stop does not win.
    @ObservationIgnored private var wanted = false

    /// The port it listens on unless told otherwise: fixed, so that an address given to a
    /// friend yesterday still works today.
    public static let defaultPort = 8787

    /// - Parameter staysOnThisMachine: Keeps the server to this Mac. For checks and tests, which
    ///   must not make macOS ask about the network.
    public init(staysOnThisMachine: Bool, logSubsystem: String = "party") {
        reach = staysOnThisMachine ? .thisMac : .localNetwork
        logger = Logger(subsystem: logSubsystem, category: "party")
    }

    public var isRunning: Bool {
        server != nil
    }

    /// Starts or stops the server to match the setting. Safe to call with what is already so.
    public func setRunning(_ shouldRun: Bool, port: Int = PartyHost.defaultPort) async {
        wanted = shouldRun
        guard shouldRun else {
            running?.stop()
            running = nil
            server = nil
            problem = nil
            return
        }
        guard running == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let host = try PartyHostServer(reach: reach, port: UInt16(exactly: port))
            let address = try await host.start()
            guard wanted else {
                host.stop()
                return
            }
            guard let server = PartyServer(address.absoluteString) else {
                host.stop()
                problem = "This Mac is not on a network others can reach it on."
                return
            }
            running = host
            self.server = server
            problem = nil
        } catch {
            logger.error("the party server did not start: \(String(describing: error), privacy: .public)")
            problem = "The party server could not be started. Something else may be using port \(port)."
        }
    }

    /// What to tell the user about who can use the server.
    public var reachNote: String {
        guard let server else {
            return "Lets people on the same Wi-Fi or network start and join watch parties through this Mac. Nothing has to be hosted anywhere."
        }
        if server.isLocal {
            return "Running for this Mac only: it is not on a network others can reach it on."
        }
        return """
        Running at \(server.url.absoluteString). People on the same network can join parties you start. \
        It stops when \(ProcessInfo.processInfo.processName) quits; for friends elsewhere, a server has to be hosted on the internet.
        """
    }
}
