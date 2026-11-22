import AppKit
import AVFoundation
import Foundation
import Observation
import PlayerKit
import SwiftUI
import WatchParty

/// Watch parties, as the rest of the app deals with them: starting one, joining one with an
/// invitation, leaving, and the party that is on, if any.
@MainActor
@Observable
public final class PartyCenter {
    /// The party this app is in.
    public private(set) var session: PartySession?
    /// Drives the sheet for starting or joining a party.
    public var isSetupPresented = false
    /// The invitation being typed or pasted.
    public var joinText = ""
    /// What went wrong last, in words for the person.
    public var errorMessage: String?
    /// Chat messages from others that have arrived while the party's panel was closed.
    public private(set) var unreadCount = 0
    /// Whether the invitation was put on the clipboard a moment ago.
    public private(set) var didCopyInvite = false

    @ObservationIgnored public let environment: PartyEnvironment
    @ObservationIgnored private let settings: SettingsModel
    @ObservationIgnored private let coordinator: PlayerCoordinator
    @ObservationIgnored private let bridge: PlayerPartyBridge
    @ObservationIgnored private let makeTransport: @MainActor (PartyInvite, MemberID) -> any PartyTransport
    @ObservationIgnored private let requestMicrophone: @MainActor () async -> Bool
    @ObservationIgnored private let copyToClipboard: @MainActor (String) -> Void
    /// Called to show the page of what the party is watching.
    @ObservationIgnored public var onOpenContent: (@MainActor (PartyContent.CatalogReference) -> Void)?
    /// The app's main window, which is brought forward when that page is asked for from the player.
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored private var seenMessages = 0
    @ObservationIgnored private var isPanelShowing = false
    @ObservationIgnored private var copiedTask: Task<Void, Never>?

    /// - Parameters:
    ///   - makeTransport: Connects to a party; `nil` uses WebRTC. Tests pass one without a network.
    ///   - requestMicrophone: Asks the system for the microphone and says whether it may be used.
    ///   - copyToClipboard: Puts text on the clipboard.
    public init(
        environment: PartyEnvironment,
        settings: SettingsModel,
        coordinator: PlayerCoordinator,
        streamPlayer: StreamPlayer? = nil,
        makeTransport: (@MainActor (PartyInvite, MemberID) -> any PartyTransport)? = nil,
        requestMicrophone: (@MainActor () async -> Bool)? = nil,
        copyToClipboard: (@MainActor (String) -> Void)? = nil
    ) {
        self.environment = environment
        self.settings = settings
        self.coordinator = coordinator
        bridge = PlayerPartyBridge(coordinator: coordinator, streamPlayer: streamPlayer)
        self.makeTransport = makeTransport ?? { [hostBox] invite, me in
            WebRTCTransport(configuration: .init(
                invite: invite,
                me: me,
                userAgent: environment.userAgent,
                // An invitation to a server on this machine is a check, whatever else is set.
                staysOnThisMachine: environment.staysOnThisMachine || invite.server.isLocal,
                allowsVoice: environment.allowsVoice,
                logSubsystem: environment.logSubsystem,
                // The Mac that runs the party's server reaches it without going out onto the network.
                signalingURL: hostBox.host?.server == invite.server ? invite.server.socketURLOnThisMachine : nil
            ))
        }
        self.requestMicrophone = requestMicrophone ?? Self.askForMicrophone
        self.copyToClipboard = copyToClipboard ?? { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        // The party's panel is always there in the player: it is where one is started, too.
        coordinator.accessory = PlayerAccessory(title: "Watch Party", systemImage: "person.2.fill", content: AnyView(PartyPanel(center: self)))
    }

    // MARK: - Who and where

    /// The name the others see. Until the person chooses one, their first name as the Mac knows it.
    public var displayName: String {
        get {
            let chosen = settings.settings.partyName.trimmingCharacters(in: .whitespacesAndNewlines)
            return chosen.isEmpty ? Self.defaultName : chosen
        }
        set { settings.settings.partyName = String(newValue.prefix(40)) }
    }

    static var defaultName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "Guest"
    }

    /// The party server this Mac runs itself, when it does.
    @ObservationIgnored public var host: PartyHost? {
        get { hostBox.host }
        set { hostBox.host = newValue }
    }

    /// Holds the host where the closure that makes connections can see it.
    @MainActor
    private final class HostBox {
        var host: PartyHost?
    }

    @ObservationIgnored private let hostBox = HostBox()

    /// Knows whether macOS lets the app onto the local network. `nil` never asks.
    @ObservationIgnored public var localNetwork: LocalNetworkGate?

    /// What to tell someone whose party is at a server on the local network and is not
    /// connecting: macOS keeps an app off the local network until the user lets it on, and a
    /// refusal looks to the app like a network that is not there.
    public nonisolated static func localNetworkHint(server: PartyServer, connection: PartySession.Connection, appName: String) -> String? {
        guard server.isOnLocalNetwork, connection == .connecting || connection == .reconnecting else { return nil }
        return """
        If this does not connect: on each Mac open System Settings › Privacy & Security › Local Network and switch \(appName) on, \
        then leave the party and join again.
        """
    }

    /// The name of the app, for messages.
    public var appName: String {
        environment.appName
    }

    /// The server a new party is started at: the one this Mac is running, else the one named
    /// in Settings, else the one the build came with.
    public var server: PartyServer? {
        host?.server ?? PartyServer(settings.settings.partyServer) ?? environment.builtInServer
    }

    // MARK: - Starting, joining, leaving

    /// Starts a party and puts its invitation on the clipboard, ready to send to friends.
    public func startParty() {
        guard session == nil else { return }
        guard let server else {
            errorMessage = "No party server is set up. Start one or name one in Settings › Watch Party, or join a friend's party with their invitation link."
            return
        }
        begin(PartyInvite.make(server: server), isHost: true)
        copyInvite()
    }

    /// Joins the party whose invitation is in `joinText`.
    public func joinParty() {
        guard session == nil else { return }
        guard let invite = PartyInvite(joinText, defaultServer: server) else {
            errorMessage = "That is not a watch party invitation. Paste the whole link your friend sent."
            return
        }
        begin(invite, isHost: false)
    }

    /// Gets into a party with a given invitation. Does not touch the clipboard.
    public func begin(_ invite: PartyInvite, isHost: Bool) {
        guard session == nil else { return }
        errorMessage = nil
        let me = MemberID.random()
        let session = PartySession(
            invite: invite, isHost: isHost, name: displayName, me: me,
            transport: makeTransport(invite, me), playback: bridge
        )
        self.session = session
        seenMessages = 0
        unreadCount = 0
        joinText = ""
        isSetupPresented = false
        if invite.server.isOnLocalNetwork {
            // The party's server and the people in it are on this network: without macOS's
            // leave to use it nothing will connect, and nothing will say why.
            localNetwork?.refresh()
        }
        session.start()
        follow(session)
    }

    public func leave() {
        session?.leave()
        session = nil
        unreadCount = 0
        coordinator.setAccessoryBadge(0)
    }

    public func copyInvite() {
        guard let session else { return }
        copyToClipboard(session.invite.link)
        didCopyInvite = true
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                self?.didCopyInvite = false
            }
        }
    }

    /// Shows the page of what the party is watching, in the main window.
    public func openPartyContent() {
        guard let catalog = session?.content?.catalog else { return }
        onOpenContent?(catalog)
        // Asked for from the player, the page would otherwise open behind it.
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Voice

    /// Whether the voice chat can be used in this run of the app.
    public var allowsVoice: Bool {
        environment.allowsVoice
    }

    /// Joins the voice chat, asking for the microphone first, or leaves it.
    public func toggleVoice() async {
        guard let session else { return }
        if session.inVoice {
            session.setVoice(inVoice: false)
            return
        }
        guard environment.allowsVoice else {
            errorMessage = "Voice is switched off in this run of the app."
            return
        }
        guard await requestMicrophone() else {
            errorMessage = "\(environment.appName) may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
            return
        }
        // The party may have ended while the question was on screen.
        guard self.session === session else { return }
        session.setVoice(inVoice: true)
    }

    public func toggleMute() {
        guard let session, session.inVoice else { return }
        session.setVoice(inVoice: true, isMuted: !session.isMuted)
    }

    private static func askForMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    // MARK: - Following the party

    /// The panel says when it is on screen, which is when messages count as read.
    func panelIsShowing(_ isShowing: Bool) {
        isPanelShowing = isShowing
        if isShowing {
            markRead()
        }
    }

    private func markRead() {
        seenMessages = othersMessages
        if unreadCount != 0 {
            unreadCount = 0
        }
        coordinator.setAccessoryBadge(0)
    }

    private var othersMessages: Int {
        guard let session else { return 0 }
        return session.chat.count { entry in
            if case let .message(author, _) = entry.kind {
                return author != session.me
            }
            return false
        }
    }

    /// Keeps the unread count current and notices a party that could not be joined.
    private func follow(_ session: PartySession) {
        let (connection, _) = withObservationTracking {
            (session.connection, session.chat.count)
        } onChange: { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.follow(session)
            }
        }
        if case let .failed(message) = connection {
            errorMessage = message
            self.session = nil
            return
        }
        if isPanelShowing {
            markRead()
        } else {
            let unread = max(othersMessages - seenMessages, 0)
            if unread != unreadCount {
                unreadCount = unread
            }
            coordinator.setAccessoryBadge(unread)
        }
    }
}
