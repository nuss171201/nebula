@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary
import PlayerKit
import StreamEngine
import Testing
import WatchParty
import WatchPartyTestSupport

/// Ninety seconds of video, written by `Scripts/make-test-media.sh`.
private let longSample = URL(filePath: #filePath)
    .deletingLastPathComponent() // AppUITests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // AppUI
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // repository root
    .appending(path: "TestMedia/long-low-res.mp4")

private let hasLongSample = FileManager.default.fileExists(atPath: longSample.path)

/// What a party centre did to the world outside it, and what the world answers.
@MainActor
final class PartyRecorder {
    var clipboard: [String] = []
    var microphoneAnswer = true
    var microphoneRequests = 0
    var transports: [InMemoryTransport] = []
}

/// One person's app, as far as a party goes: a real player without a window or sound, settings
/// that live in memory, and the party centre between them.
@MainActor
final class PartySide {
    let coordinator: PlayerCoordinator
    let settings: SettingsModel
    let center: PartyCenter
    let recorder = PartyRecorder()
    private let manager: StreamManager

    /// - Parameter network: Where parties meet without a network; `nil` uses real connections on this machine.
    init(name: String, network: InMemoryPartyNetwork?, server: String? = "https://party.example.com", allowsVoice: Bool = true) throws {
        coordinator = PlayerCoordinator(
            configuration: PlayerConfiguration(
                userAgent: "AppUITests/1.0", logSubsystem: "test.appui", videoOutput: .none, playsAudio: false, resumesPlayback: false
            ),
            presentsWindow: false
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("party-tests-\(UUID().uuidString)", isDirectory: true)
        manager = StreamManager(settings: .loopback(), cache: StreamCache(directory: folder))
        let streamPlayer = StreamPlayer(coordinator: coordinator, manager: manager)
        settings = try SettingsModel(
            store: SettingsStore(database: LibraryDatabase.inMemory()),
            coordinator: coordinator,
            streamManager: manager,
            nextEpisode: NextEpisodeController(
                coordinator: coordinator, streamPlayer: streamPlayer, client: AddonClient(http: URLSessionHTTPClient(userAgent: "Tests/1.0"))
            ),
            sleep: { _ in }
        )
        settings.settings.partyName = name
        let environment = PartyEnvironment(
            builtInServer: server.flatMap(PartyServer.init), staysOnThisMachine: true, allowsVoice: allowsVoice,
            appName: "Tests", userAgent: "AppUITests/1.0", logSubsystem: "test.appui"
        )
        let recorder = recorder
        var makeTransport: (@MainActor (PartyInvite, MemberID) -> any PartyTransport)?
        if let network {
            makeTransport = { _, me in
                let transport = network.makeTransport(for: me)
                recorder.transports.append(transport)
                return transport
            }
        }
        center = PartyCenter(
            environment: environment,
            settings: settings,
            coordinator: coordinator,
            streamPlayer: streamPlayer,
            makeTransport: makeTransport,
            requestMicrophone: {
                recorder.microphoneRequests += 1
                return recorder.microphoneAnswer
            },
            copyToClipboard: { recorder.clipboard.append($0) }
        )
    }

    var clipboard: [String] {
        recorder.clipboard
    }

    var player: PlayerModel? {
        coordinator.player
    }

    /// Where the engine itself says playback is.
    var position: Double {
        player?.engineProperty("time-pos").flatMap(Double.init) ?? -1
    }

    func open(_ file: URL) async {
        coordinator.play(fileURL: file)
        for _ in 0 ..< 500 where player?.state.phase != .playing {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func shutDown() async {
        center.leave()
        coordinator.closePlayer()
        await manager.shutdown()
    }
}

@MainActor
private func eventually(
    _ what: String, within seconds: Double = 20, sourceLocation: SourceLocation = #_sourceLocation, _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(40))
    }
    Issue.record("timed out waiting for: \(what)", sourceLocation: sourceLocation)
}

@MainActor
@Suite("Watch parties in the app", .serialized)
struct PartyTests {
    /// How far apart the two engines are right now.
    private func gap(_ first: PartySide, _ second: PartySide) -> Double {
        abs(first.position - second.position)
    }

    @Test(
        "Two real players are kept together through joining, pausing, jumping and a change of speed",
        .enabled(if: hasLongSample, "run Scripts/make-test-media.sh first")
    )
    func twoPlayersStayTogether() async throws {
        let network = InMemoryPartyNetwork()
        let host = try PartySide(name: "Asha", network: network)
        let guest = try PartySide(name: "Ravi", network: network)

        await host.open(longSample)
        host.player?.seek(to: 30)
        await eventually("the host is half a minute in") { host.position > 30 }
        host.center.startParty()
        let link = try #require(host.clipboard.last)
        #expect(link.hasPrefix("https://party.example.com/#"))
        #expect(host.center.didCopyInvite)

        guest.center.joinText = link
        guest.center.joinParty()
        #expect(guest.center.errorMessage == nil)
        await eventually("they see each other") { host.center.session?.people.count == 2 && guest.center.session?.people.count == 2 }
        await eventually("the guest is told what is on") { guest.center.session?.content?.title == "long-low-res.mp4" }
        #expect(guest.center.session?.isElsewhere == true)

        await guest.open(longSample)
        await eventually("the guest has caught up") { guest.position > 30 && gap(host, guest) < 0.25 }
        await eventually("both count as watching") { host.center.session?.people.allSatisfy { $0.activity == .ready } == true }

        // The host pauses: the guest stops on the same frame, give or take.
        host.player?.setPaused(true)
        await eventually("the guest is paused at the same place") {
            guest.player?.state.isPaused == true && gap(host, guest) <= SyncTuning.pausedTolerance + 0.05
        }

        // The guest jumps while paused: the host goes there too, and stays paused.
        guest.player?.seek(to: 60)
        await eventually("the host followed the jump") { abs(host.position - 60) < 0.2 && abs(guest.position - 60) < 0.2 }
        #expect(host.player?.state.isPaused == true)
        #expect(host.center.session?.chat.contains { $0.text == "Ravi jumped to 1:00." } == true)

        // The guest resumes and plays faster: so does the host.
        guest.player?.setPaused(false)
        guest.player?.speed = PlaybackSpeed(1.5)
        await eventually("both are playing at the new speed") {
            host.player?.state.isPaused == false && host.player?.speed.value == 1.5 && host.position > 62 && gap(host, guest) < 0.3
        }
        // The speed the person sees is the shared one; the small corrections stay out of sight.
        #expect(guest.player?.speed.value == 1.5)

        guest.center.leave()
        await eventually("the host sees the guest go") { host.center.session?.people.count == 1 }
        #expect(guest.center.session == nil)
        #expect(guest.player?.speedAdjustment == 1)
        await host.shutDown()
        await guest.shutDown()
    }

    @Test("With the controls left to the host, a guest's pause does not stick or spread", .enabled(if: hasLongSample, "run Scripts/make-test-media.sh first"))
    func hostOnly() async throws {
        let network = InMemoryPartyNetwork()
        let host = try PartySide(name: "Asha", network: network)
        let guest = try PartySide(name: "Ravi", network: network)
        await host.open(longSample)
        host.center.startParty()
        guest.center.joinText = try #require(host.clipboard.last)
        guest.center.joinParty()
        await guest.open(longSample)
        await eventually("in step") { host.center.session?.people.allSatisfy { $0.activity == .ready } == true && gap(host, guest) < 0.25 }

        host.center.session?.setEveryoneControls(false)
        await eventually("the guest is told") { guest.center.session?.canControl == false }
        guest.player?.setPaused(true)
        await eventually("the guest is playing again") { guest.player?.state.isPaused == false }
        #expect(host.player?.state.isPaused == false)
        #expect(guest.player?.notice?.text == "Only the host controls playback in this party.")
        await host.shutDown()
        await guest.shutDown()
    }

    @Test("Starting needs a server, joining needs an invitation, and a link brings its own server")
    func startingAndJoining() async throws {
        let network = InMemoryPartyNetwork()
        let unconfigured = try PartySide(name: "Mei", network: network, server: nil)
        #expect(unconfigured.center.server == nil)
        unconfigured.center.startParty()
        #expect(unconfigured.center.session == nil)
        #expect(unconfigured.center.errorMessage?.hasPrefix("No party server is set up.") == true)
        #expect(unconfigured.clipboard.isEmpty)

        unconfigured.center.joinText = "see you at eight"
        unconfigured.center.joinParty()
        #expect(unconfigured.center.session == nil)
        #expect(unconfigured.center.errorMessage == "That is not a watch party invitation. Paste the whole link your friend sent.")

        // A server named in Settings is used for starting; a bad one is not.
        unconfigured.settings.settings.partyServer = "party.example.org"
        #expect(unconfigured.center.server == nil)
        unconfigured.settings.settings.partyServer = "https://party.example.org"
        #expect(unconfigured.center.server?.url.absoluteString == "https://party.example.org/")

        let host = try PartySide(name: "Asha", network: network)
        host.center.startParty()
        let link = try #require(host.clipboard.last)
        unconfigured.settings.settings.partyServer = ""
        unconfigured.center.joinText = "  \(link)\n"
        unconfigured.center.joinParty()
        #expect(unconfigured.center.errorMessage == nil)
        #expect(unconfigured.center.session?.invite == host.center.session?.invite)
        #expect(unconfigured.center.joinText.isEmpty)
        await eventually("they meet") { host.center.session?.people.map(\.name) == ["Asha", "Mei"] }
        #expect(host.center.session?.isHost == true)
        #expect(unconfigured.center.session?.isHost == false)
        await host.shutDown()
        await unconfigured.shutDown()
    }

    @Test("Messages from others count as unread until the panel is looked at")
    func unreadMessages() async throws {
        let network = InMemoryPartyNetwork()
        let host = try PartySide(name: "Asha", network: network)
        let guest = try PartySide(name: "Ravi", network: network)
        host.center.startParty()
        guest.center.joinText = try #require(host.clipboard.last)
        guest.center.joinParty()
        await eventually("connected") { host.center.session?.people.count == 2 }

        guest.center.session?.send("are we starting?")
        guest.center.session?.send("popcorn is ready")
        host.center.session?.send("one minute")
        await eventually("two unread for the host") { host.center.unreadCount == 2 }
        await eventually("one unread for the guest") { guest.center.unreadCount == 1 }

        host.center.panelIsShowing(true)
        #expect(host.center.unreadCount == 0)
        guest.center.session?.send("ok")
        await eventually("it arrives") { host.center.session?.chat.last?.text == "ok" }
        #expect(host.center.unreadCount == 0)
        host.center.panelIsShowing(false)
        guest.center.session?.send("now?")
        await eventually("unread again once the panel is closed") { host.center.unreadCount == 1 }
        await host.shutDown()
        await guest.shutDown()
    }

    @Test("Voice asks for the microphone first, and stays off where the app was started without it")
    func voice() async throws {
        let network = InMemoryPartyNetwork()
        let host = try PartySide(name: "Asha", network: network)
        host.center.startParty()

        host.recorder.microphoneAnswer = false
        await host.center.toggleVoice()
        #expect(host.center.session?.inVoice == false)
        #expect(host.center.errorMessage == "Tests may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone.")
        #expect(host.recorder.transports.last?.voiceRequests.isEmpty == true)

        host.recorder.microphoneAnswer = true
        await host.center.toggleVoice()
        #expect(host.center.session?.inVoice == true)
        host.center.toggleMute()
        #expect(host.center.session?.isMuted == true)
        await host.center.toggleVoice()
        #expect(host.center.session?.inVoice == false)
        #expect(host.center.session?.isMuted == false)
        #expect(host.recorder.transports.last?.voiceRequests == [true, true, false])
        #expect(host.recorder.microphoneRequests == 2)

        let silent = try PartySide(name: "Ravi", network: network, allowsVoice: false)
        silent.center.joinText = try #require(host.clipboard.last)
        silent.center.joinParty()
        await silent.center.toggleVoice()
        #expect(silent.center.session?.inVoice == false)
        #expect(silent.recorder.microphoneRequests == 0)
        #expect(silent.center.errorMessage == "Voice is switched off in this run of the app.")
        await host.shutDown()
        await silent.shutDown()
    }

    @Test(
        "Over real connections on this machine: two players meet through a signalling server and stay together",
        .enabled(if: hasLongSample, "run Scripts/make-test-media.sh first")
    )
    func overWebRTC() async throws {
        let server = try LoopbackSignalServer()
        defer { server.stop() }
        let address = try await server.start().absoluteString
        let host = try PartySide(name: "Asha", network: nil, server: address)
        let guest = try PartySide(name: "Ravi", network: nil, server: nil)

        await host.open(longSample)
        host.player?.seek(to: 20)
        host.center.startParty()
        guest.center.joinText = try #require(host.clipboard.last)
        guest.center.joinParty()
        await eventually("connected") { guest.center.session?.connection == .connected && guest.center.session?.people.count == 2 }
        await guest.open(longSample)
        await eventually("in step") { guest.position > 20 && gap(host, guest) < 0.25 }

        guest.center.session?.send("hello over the wire")
        await eventually("chat arrives") { host.center.session?.chat.last?.text == "hello over the wire" }
        host.player?.setPaused(true)
        await eventually("paused together") { guest.player?.state.isPaused == true && gap(host, guest) <= SyncTuning.pausedTolerance + 0.05 }
        await host.shutDown()
        await guest.shutDown()
    }
}

@Suite("Watch party settings and the player's side of a party")
struct PartySupportTests {
    @Test("The party's settings are stored with the rest and read back leniently")
    func settingsRoundTrip() throws {
        var settings = AppSettings()
        settings.partyName = "Asha"
        settings.partyServer = "https://party.example.com"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        // Settings written before parties existed, or with something odd in their place.
        let older = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"appearance":"dark","partyName":7}"#.utf8))
        #expect(older.partyName.isEmpty)
        #expect(older.partyServer.isEmpty)
        #expect(older.appearance == .dark)
    }

    @Test("The built-in server comes from Info.plist, if it names a usable one", arguments: [
        ("https://party.example.com", "https://party.example.com/"), ("", nil), ("party.example.com", nil), ("http://party.example.com", nil),
    ] as [(String, String?)])
    func builtInServer(value: String, expected: String?) {
        #expect(PartyEnvironment.builtInServer(infoDictionary: [PartyEnvironment.serverInfoKey: value])?.url.absoluteString == expected)
        #expect(PartyEnvironment.builtInServer(infoDictionary: nil) == nil)
    }

    @MainActor
    @Test("A stream that is paused with next to nothing buffered is not ready to be resumed")
    func stalledWhilePaused() {
        var state = PlaybackState()
        state.apply(.fileLoaded)
        state.apply(.property(.duration(600)))
        state.apply(.property(.position(100)))
        #expect(!PlayerPartyBridge.isStalled(state, isLocalFile: false))
        state.apply(.property(.waitingForData(true)))
        #expect(PlayerPartyBridge.isStalled(state, isLocalFile: true))
        state.apply(.property(.waitingForData(false)))
        state.apply(.property(.seeking(true)))
        #expect(PlayerPartyBridge.isStalled(state, isLocalFile: true))
        state.apply(.property(.seeking(false)))

        state.apply(.property(.paused(true)))
        state.apply(.property(.bufferedAhead(0.4)))
        #expect(PlayerPartyBridge.isStalled(state, isLocalFile: false))
        // A file on disk is always there; so is a stream with a few seconds in hand, or one at its end.
        #expect(!PlayerPartyBridge.isStalled(state, isLocalFile: true))
        state.apply(.property(.bufferedAhead(5)))
        #expect(!PlayerPartyBridge.isStalled(state, isLocalFile: false))
        state.apply(.property(.bufferedAhead(0.4)))
        state.apply(.property(.position(598.5)))
        #expect(!PlayerPartyBridge.isStalled(state, isLocalFile: false))
    }

    @Test("What people are doing, in words")
    func words() {
        #expect(PartyText.describe(.ready, otherTitle: nil) == "Watching")
        #expect(PartyText.describe(.away, otherTitle: nil) == "Not watching yet")
        #expect(PartyText.describe(.away, otherTitle: "Another Film") == "Watching Another Film")
        #expect(PartyText.describe(.stalled, otherTitle: nil) == "Buffering")
        #expect(PartyText.people(1) == "Only you so far")
        #expect(PartyText.people(3) == "3 people")
        #expect(PartyNotices.connectionText(.connected) == nil)
        #expect(PartyNotices.connectionText(.connecting) == "Connecting…")
    }
}
