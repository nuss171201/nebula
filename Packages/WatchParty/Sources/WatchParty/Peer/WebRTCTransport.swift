import Foundation
import os
@preconcurrency import WebRTC

/// The party over WebRTC: a direct, encrypted connection to every other person, set up with the
/// signalling server's help. Messages travel on a data channel; voice, for those who join it, as
/// audio on the same connection.
public final class WebRTCTransport: PartyTransport, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var invite: PartyInvite
        public var me: MemberID
        public var userAgent: String
        /// Keeps every connection on this machine: no helper servers, no network interfaces but
        /// the loopback one. For tests and checks, which must not make macOS ask about the network.
        public var staysOnThisMachine: Bool
        /// `false` makes joining the voice chat do nothing, so that no microphone is opened and
        /// no sound is played. For tests and silent checks.
        public var allowsVoice: Bool
        public var logSubsystem: String

        public init(
            invite: PartyInvite, me: MemberID, userAgent: String, staysOnThisMachine: Bool = false,
            allowsVoice: Bool = true, logSubsystem: String
        ) {
            self.invite = invite
            self.me = me
            self.userAgent = userAgent
            self.staysOnThisMachine = staysOnThisMachine
            self.allowsVoice = allowsVoice
            self.logSubsystem = logSubsystem
        }
    }

    public let events: AsyncStream<TransportEvent>
    let configuration: Configuration
    let logger: Logger
    /// Everything below is read and written on this queue only.
    let queue = DispatchQueue(label: "watch-party.mesh")
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let seal: SignalSeal
    let factory: RTCPeerConnectionFactory

    var links: [MemberID: PeerLink] = [:]
    /// Who the signalling server says is in the room.
    var roster: Set<MemberID> = []
    var iceServers: [IceServer] = []
    var signaling: SignalingConnection?
    private var signalingTask: Task<Void, Never>?
    var isStopped = false
    var reconnectAttempts: [MemberID: Int] = [:]
    // Voice.
    var isVoiceEnabled = false
    var isMuted = false
    var microphone: RTCAudioTrack?

    private static let prepare: Void = {
        RTCInitializeSSL()
    }()

    public init(configuration: Configuration) {
        Self.prepare
        self.configuration = configuration
        logger = Logger(subsystem: configuration.logSubsystem, category: "party")
        seal = configuration.invite.seal
        (events, continuation) = AsyncStream<TransportEvent>.makeStream()
        factory = RTCPeerConnectionFactory()
        if configuration.staysOnThisMachine {
            let options = RTCPeerConnectionFactoryOptions()
            options.ignoreLoopbackNetworkAdapter = false
            options.ignoreWiFiNetworkAdapter = true
            options.ignoreEthernetNetworkAdapter = true
            options.ignoreCellularNetworkAdapter = true
            options.ignoreVPNNetworkAdapter = true
            options.disableNetworkMonitor = true
            factory.setOptions(options)
        }
    }

    // MARK: - PartyTransport

    public func start() {
        queue.async { [self] in
            guard signalingTask == nil, !isStopped else { return }
            signalingTask = Task { [weak self] in
                await self?.runSignaling()
            }
        }
    }

    public func send(_ data: Data, to recipient: MemberID?) {
        queue.async { [self] in
            let buffer = RTCDataBuffer(data: data, isBinary: false)
            for link in links.values where link.isOpen && (recipient == nil || recipient == link.id) {
                link.channel?.sendData(buffer)
            }
        }
    }

    public func setVoice(isEnabled: Bool, isMuted: Bool) {
        queue.async { [self] in
            applyVoice(isEnabled: isEnabled && configuration.allowsVoice, isMuted: isMuted)
        }
    }

    public func stop() {
        queue.async { [self] in
            guard !isStopped else { return }
            isStopped = true
            signalingTask?.cancel()
            for link in links.values {
                relay(.bye, to: link.id)
                link.close()
            }
            links = [:]
            signaling?.enqueue(.leave)
            // Gives the goodbyes a moment to leave before the socket closes.
            let closing = signaling
            signaling = nil
            queue.asyncAfter(deadline: .now() + 0.3) {
                closing?.close()
            }
            microphone = nil
            continuation.finish()
        }
    }

    func emit(_ event: TransportEvent) {
        continuation.yield(event)
    }

    // MARK: - Signalling

    private func runSignaling() async {
        var attempt = 0
        emit(.signaling(.connecting))
        while !Task.isCancelled {
            let connection = SignalingConnection(url: configuration.invite.server.socketURL, userAgent: configuration.userAgent)
            connection.enqueue(.join(room: configuration.invite.roomID, peer: configuration.me))
            queue.async { [self] in
                if isStopped {
                    connection.close()
                } else {
                    signaling = connection
                }
            }
            let keepAlive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    connection.checkAlive(silenceLimit: .seconds(50))
                }
            }
            var refusal: PartyFailure?
            do {
                while refusal == nil {
                    let frame = try await connection.receive()
                    attempt = 0
                    if case let .error(code) = frame {
                        refusal = code == "room-full" ? .roomFull : .refused(code)
                    } else {
                        queue.async { [self] in handle(frame) }
                    }
                }
            } catch {
                logger.notice("signalling connection ended: \(error.localizedDescription, privacy: .public)")
            }
            keepAlive.cancel()
            connection.close()
            queue.async { [self] in
                if signaling === connection {
                    signaling = nil
                }
            }
            if let refusal {
                emit(.failed(refusal))
                return
            }
            guard !Task.isCancelled else { return }
            attempt += 1
            emit(.signaling(.retrying(attempt: attempt)))
            // Half a second at first, doubling up to fifteen: the party is worth waiting for.
            let delay = min(0.5 * pow(2, Double(attempt - 1)), 15) * Double.random(in: 0.8 ... 1.2)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func handle(_ frame: ServerFrame) {
        guard !isStopped else { return }
        switch frame {
        case let .joined(peers, servers):
            roster = Set(peers.filter { $0 != configuration.me })
            iceServers = servers
            emit(.signaling(.connected))
            // The one who arrives proposes to everyone already there.
            for peer in roster.sorted() where links[peer] == nil {
                let link = makeLink(to: peer)
                link.needsNegotiation = true
                negotiateIfNeeded(link)
            }
        case let .peerJoined(peer):
            roster.insert(peer)
        case let .peerLeft(peer):
            roster.remove(peer)
            // A connection that is up does not need the server; one still being made does.
            if let link = links[peer], !link.isOpen {
                drop(link, announce: false)
            }
        case let .relayed(sender, data):
            guard sender != configuration.me, let payload = seal.open(data, from: sender, to: configuration.me) else {
                logger.notice("ignored a signalling message that could not be opened")
                return
            }
            receive(payload, from: sender)
        case .error:
            break
        }
    }

    func relay(_ payload: SignalPayload, to peer: MemberID) {
        guard let data = seal.seal(payload, from: configuration.me, to: peer) else { return }
        signaling?.enqueue(.relay(to: peer, data: data))
    }
}
