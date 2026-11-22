import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import Testing
import WatchParty

/// A sign-in service that answers from a script and remembers what it was asked.
private final class ScriptedService: @unchecked Sendable {
    struct Answer {
        var status = 200
        var body = "{}"
        var failure: URLError.Code?
    }

    private let lock = NSLock()
    private var answers: [Answer]
    private(set) var requests: [URLRequest] = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    var transport: AccountClient.Transport {
        { [self] request in
            let answer: Answer = lock.withLock {
                requests.append(request)
                return answers.isEmpty ? Answer(status: 500) : answers.removeFirst()
            }
            if let failure = answer.failure {
                throw URLError(failure)
            }
            let response = HTTPURLResponse(url: request.url ?? URL(filePath: "/"), statusCode: answer.status, httpVersion: nil, headerFields: nil)
            return (Data(answer.body.utf8), response ?? URLResponse())
        }
    }

    var seen: [URLRequest] {
        lock.withLock { requests }
    }

    func body(_ index: Int) -> [String: String] {
        (seen[index].httpBody).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
}

private let sessionJSON = """
{"access_token": "access-1", "token_type": "bearer", "expires_in": 3600, "refresh_token": "refresh-1",
 "user": {"id": "user-1", "email": "asha@example.com", "role": "authenticated"}}
"""

private func makeClient(_ service: ScriptedService, now: Date = Date(timeIntervalSince1970: 1000)) throws -> AccountClient {
    let configuration = try #require(AccountConfiguration(address: "https://project.example.co/", publicKey: " public-key "))
    return AccountClient(
        configuration: configuration,
        retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1), maxDelay: .milliseconds(2)),
        now: { now },
        transport: service.transport
    )
}

@Suite("The sign-in service, as the app speaks to it")
struct AccountClientTests {
    @Test("A build names its sign-in service with a secure address and a key, or has no accounts")
    func configuration() {
        let good = AccountConfiguration(address: "https://abc.supabase.co/some/path?x=1", publicKey: "key")
        #expect(good?.url.absoluteString == "https://abc.supabase.co" && good?.publicKey == "key")
        #expect(AccountConfiguration(address: "http://127.0.0.1:5432", publicKey: "key") != nil)
        let unusable = [
            ("", "key"), ("https://abc.supabase.co", " "), ("http://abc.supabase.co", "key"), ("abc.supabase.co", "key"),
            ("https://user:pw@abc.co", "key"),
        ]
        for (address, key) in unusable {
            #expect(AccountConfiguration(address: address, publicKey: key) == nil, "\(address) with key '\(key)' should be no configuration")
        }
        #expect(AccountConfiguration(infoDictionary: ["AccountServerURL": "https://abc.supabase.co", "AccountPublicKey": "key"]) != nil)
        // What an empty build setting comes to in the Info.plist.
        #expect(AccountConfiguration(infoDictionary: ["AccountServerURL": "", "AccountPublicKey": ""]) == nil)
        #expect(AccountConfiguration(infoDictionary: nil) == nil)
    }

    @Test("Logging in sends the email and password to the service and brings back a session")
    func logIn() async throws {
        let service = ScriptedService([.init(body: sessionJSON)])
        let client = try makeClient(service)
        let session = try await client.logIn(email: "asha@example.com", password: "correct horse")
        #expect(session.email == "asha@example.com" && session.userID == "user-1")
        #expect(session.expiresAt == Date(timeIntervalSince1970: 4600) && !session.needsRefresh(now: Date(timeIntervalSince1970: 1000)))
        #expect(session.needsRefresh(now: Date(timeIntervalSince1970: 4500)))

        let request = try #require(service.seen.first)
        #expect(request.url?.absoluteString == "https://project.example.co/auth/v1/token?grant_type=password")
        #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "apikey") == "public-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer public-key")
        #expect(service.body(0) == ["email": "asha@example.com", "password": "correct horse"])
    }

    @Test("Creating an account either signs in at once or waits for the email to be confirmed")
    func signUp() async throws {
        let service = ScriptedService([
            .init(body: sessionJSON),
            .init(body: #"{"id": "user-2", "email": "ravi@example.com", "confirmation_sent_at": "2026-11-22T10:00:00Z"}"#),
        ])
        let client = try makeClient(service)
        guard case let .signedIn(session) = try await client.signUp(email: "asha@example.com", password: "long enough") else {
            Issue.record("expected to be signed in")
            return
        }
        #expect(session.userID == "user-1")
        #expect(try await client.signUp(email: "ravi@example.com", password: "long enough") == .confirmationSent)
        #expect(service.seen.map(\.url?.path) == ["/auth/v1/signup", "/auth/v1/signup"])
    }

    @Test("What the service refuses is said in the app's own words", arguments: [
        (400, #"{"code": 400, "error_code": "invalid_credentials", "msg": "Invalid login credentials"}"#, AccountError.wrongEmailOrPassword),
        (400, #"{"error": "invalid_grant", "error_description": "Invalid login credentials"}"#, .wrongEmailOrPassword),
        (400, #"{"error": "invalid_grant", "error_description": "Email not confirmed"}"#, .emailNotConfirmed),
        (400, #"{"code": 400, "error_code": "email_not_confirmed", "msg": "Email not confirmed"}"#, .emailNotConfirmed),
        (422, #"{"code": 422, "error_code": "user_already_exists", "msg": "User already registered"}"#, .alreadyRegistered),
        (422, #"{"code": 422, "error_code": "weak_password", "msg": "Password should be at least 6 characters."}"#, .weakPassword),
        (400, #"{"code": 400, "error_code": "email_address_invalid", "msg": "Email address is invalid"}"#, .invalidEmail),
        (429, #"{"msg": "slow down"}"#, .tooManyAttempts),
        (500, #"{"msg": "Database is on fire"}"#, .service("Database is on fire")),
        (502, "<html>Bad Gateway</html>", .service("")),
    ])
    func refusals(status: Int, body: String, expected: AccountError) async throws {
        let service = ScriptedService([.init(status: status, body: body)])
        let client = try makeClient(service)
        await #expect(throws: expected) {
            try await client.logIn(email: "asha@example.com", password: "x")
        }
        // A refusal is an answer: it is not asked for again.
        #expect(service.seen.count == 1)
        #expect(!expected.userMessage.isEmpty)
    }

    @Test("A request that cannot have arrived is tried again; one that may have is not")
    func retries() async throws {
        let unreachable = ScriptedService([.init(failure: .cannotConnectToHost), .init(failure: .notConnectedToInternet), .init(body: sessionJSON)])
        #expect(try await makeClient(unreachable).logIn(email: "a@b.co", password: "x").userID == "user-1")
        #expect(unreachable.seen.count == 3)

        // Timed out: the account may have been made. Asking again would be told it already exists.
        let lost = ScriptedService([.init(failure: .timedOut), .init(body: sessionJSON)])
        await #expect(throws: AccountError.offline) {
            try await makeClient(lost).signUp(email: "a@b.co", password: "long enough")
        }
        #expect(lost.seen.count == 1)

        let down = ScriptedService([.init(failure: .cannotFindHost), .init(failure: .cannotFindHost), .init(failure: .cannotFindHost)])
        await #expect(throws: AccountError.offline) {
            try await makeClient(down).logIn(email: "a@b.co", password: "x")
        }
    }

    @Test("A session is renewed with its refresh token; one the service no longer accepts is over")
    func refreshAndLogOut() async throws {
        let service = ScriptedService([
            .init(body: sessionJSON.replacingOccurrences(of: "access-1", with: "access-2")),
            .init(status: 400, body: #"{"error_code": "refresh_token_not_found", "msg": "Invalid Refresh Token"}"#),
            .init(status: 204, body: ""),
        ])
        let client = try makeClient(service)
        let old = try #require(AccountClient.session(from: Data(sessionJSON.utf8), now: Date(timeIntervalSince1970: 0)))
        let fresh = try await client.refresh(old)
        #expect(fresh.accessToken == "access-2")
        #expect(service.seen[0].url?.query == "grant_type=refresh_token" && service.body(0) == ["refresh_token": "refresh-1"])
        await #expect(throws: AccountError.sessionExpired) { try await client.refresh(old) }

        await client.logOut(fresh)
        // Logging out is done as the person, not as the app.
        #expect(service.seen[2].url?.path == "/auth/v1/logout" && service.seen[2].value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
    }
}

@MainActor
@Suite("The account, as Settings shows it")
struct AccountCenterTests {
    private func center(_ answers: [ScriptedService.Answer], store: FileSessionStore = FileSessionStore()) throws -> (AccountCenter, ScriptedService) {
        let service = ScriptedService(answers)
        return try (AccountCenter(client: makeClient(service, now: Date()), store: store), service)
    }

    @Test("Without a sign-in service there are no accounts, and nothing is sent anywhere")
    func unavailable() async {
        let center = AccountCenter(client: nil, store: FileSessionStore())
        #expect(center.phase == .unavailable && !center.isSignedIn)
        center.email = "asha@example.com"
        center.password = "long enough"
        await center.submit()
        await center.start()
        #expect(center.phase == .unavailable)
    }

    @Test("The form is sent only when it could be right; the password is forgotten once it has been used")
    func logIn() async throws {
        let store = FileSessionStore()
        let (center, service) = try center([.init(status: 400, body: #"{"error_code": "invalid_credentials"}"#), .init(body: sessionJSON)], store: store)
        #expect(center.phase == .signedOut && !center.canSubmit)
        center.email = "asha"
        center.password = "x"
        #expect(!center.canSubmit)
        await center.submit()
        #expect(service.seen.isEmpty)

        center.email = " asha@example.com "
        #expect(center.canSubmit)
        await center.submit()
        #expect(center.errorMessage == AccountError.wrongEmailOrPassword.userMessage && center.phase == .signedOut)
        // The address is sent without the stray spaces.
        #expect(service.body(0)["email"] == "asha@example.com")

        await center.submit()
        #expect(center.phase == .signedIn(email: "asha@example.com") && center.errorMessage == nil)
        #expect(center.password.isEmpty)
        #expect(store.load()?.userID == "user-1")
    }

    @Test("A new account needs a longer password, and may have to be confirmed by email first")
    func signUp() async throws {
        let (center, service) = try center([.init(body: #"{"id": "u", "email": "ravi@example.com"}"#)])
        center.mode = .signUp
        center.email = "ravi@example.com"
        center.password = "short"
        #expect(!center.canSubmit)
        center.password = "long enough"
        #expect(center.canSubmit)
        await center.submit()
        #expect(service.seen.first?.url?.path == "/auth/v1/signup")
        #expect(center.phase == .signedOut && center.mode == .logIn && center.password.isEmpty)
        #expect(center.notice?.contains("ravi@example.com") == true)
    }

    @Test("The next launch is still logged in; logging out forgets the session here whatever the service says")
    func staysLoggedIn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("account-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Support/account.json")
        let (first, _) = try center([.init(body: sessionJSON)], store: FileSessionStore(file: file))
        first.email = "asha@example.com"
        first.password = "correct horse"
        await first.submit()
        #expect(first.isSignedIn)
        // Readable by the user alone.
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        // The session has an hour left: nothing is asked of the service at launch.
        let (second, service) = try center([.init(failure: .cannotFindHost)], store: FileSessionStore(file: file))
        await second.start()
        #expect(second.phase == .signedIn(email: "asha@example.com") && service.seen.isEmpty)

        await second.logOut()
        #expect(second.phase == .signedOut && FileSessionStore(file: file).load() == nil)
        #expect(service.seen.first?.url?.path == "/auth/v1/logout")
    }

    @Test("A session that has run out is renewed at launch; if the service will not, the person is logged out and told")
    func renewsAtLaunch() async throws {
        let old = try #require(AccountClient.session(from: Data(sessionJSON.utf8), now: Date(timeIntervalSinceNow: -7200)))
        let renewedStore = FileSessionStore()
        renewedStore.save(old)
        let (renewed, _) = try center([.init(body: sessionJSON.replacingOccurrences(of: "refresh-1", with: "refresh-2"))], store: renewedStore)
        await renewed.start()
        #expect(renewed.isSignedIn && renewedStore.load()?.refreshToken == "refresh-2")

        let refusedStore = FileSessionStore()
        refusedStore.save(old)
        let (refused, _) = try center([.init(status: 400, body: #"{"error_code": "refresh_token_not_found"}"#)], store: refusedStore)
        await refused.start()
        #expect(refused.phase == .signedOut && refusedStore.load() == nil)
        #expect(refused.errorMessage == AccountError.sessionExpired.userMessage)

        // Offline at launch: still the same person, to be renewed another time.
        let offlineStore = FileSessionStore()
        offlineStore.save(old)
        let (offline, _) = try center([.init(failure: .timedOut)], store: offlineStore)
        await offline.start()
        #expect(offline.isSignedIn && offlineStore.load() == old)
    }

    @Test("A password reset is asked for by email address, and says the same whether or not there is an account")
    func passwordReset() async throws {
        let (center, service) = try center([.init(body: "{}")])
        await center.sendPasswordReset()
        #expect(center.errorMessage == "Enter your email address first." && service.seen.isEmpty)
        center.email = "asha@example.com"
        await center.sendPasswordReset()
        #expect(service.seen.first?.url?.path == "/auth/v1/recover" && service.body(0) == ["email": "asha@example.com"])
        #expect(center.notice?.hasPrefix("If there is an account") == true)
    }

    @Test("An address is checked for slips, not for existence", arguments: [
        ("asha@example.com", true), (" asha@example.co.uk ", true), ("a@b.c", true),
        ("asha", false), ("asha@", false), ("@example.com", false), ("asha@example", false), ("as ha@example.com", false),
        ("a@b@c.com", false), ("a@b..com", false),
    ])
    func emails(text: String, expected: Bool) {
        #expect(AccountCenter.looksLikeEmail(text) == expected)
    }
}

@MainActor
@Suite("A party server run from the app")
struct PartyHostTests {
    @Test("A server on the local network is one a party can be started at; a public address still needs https")
    func addresses() {
        for address in ["192.168.1.20", "10.0.0.5", "172.16.0.1", "172.31.255.254", "169.254.10.10"] {
            #expect(PartyServer.isPrivateAddress(address), "\(address) is on a local network")
            #expect(PartyServer("http://\(address):8787") != nil)
        }
        for address in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.1.1", "example.com", "192.168.1", "192.168.1.256", "192.168.1.1.1", ""] {
            #expect(!PartyServer.isPrivateAddress(address), "\(address) is not a local address")
        }
        #expect(PartyServer("http://8.8.8.8:8787") == nil && PartyServer("http://party.example.com") == nil)
        #expect(PartyServer("https://party.example.com") != nil)
        // A server on the local network is not "this machine": its parties make real connections.
        #expect(PartyServer("http://192.168.1.20:8787")?.isLocal == false && PartyServer("http://127.0.0.1:8787")?.isLocal == true)
        #expect(PartyServer("http://192.168.1.20:8787")?.socketURL.absoluteString == "ws://192.168.1.20:8787/ws")
    }

    @Test("Switched on, the server answers at an address parties can start at; switched off, it is gone")
    func startsAndStops() async throws {
        let host = PartyHost(staysOnThisMachine: true)
        #expect(!host.isRunning && host.server == nil)
        // Any free port, so that the test does not depend on what else this Mac is running.
        await host.setRunning(true, port: 0)
        let server = try #require(host.server)
        #expect(host.isRunning && host.problem == nil && server.isLocal)
        // A server only this Mac can reach has nobody to offer a check page to.
        #expect(host.checkAddress == nil)
        #expect(server.url.host == "127.0.0.1" && (server.url.port ?? 0) > 0)

        // It is a real party server: an app can connect and be told who else is there.
        let socket = URLSession.shared.webSocketTask(with: server.socketURL)
        socket.resume()
        try await socket.send(.string(#"{"t": "join", "room": "abcdef", "peer": "one"}"#))
        guard case let .string(answer) = try await socket.receive() else {
            Issue.record("expected a text frame")
            return
        }
        #expect(answer.contains("joined"))
        socket.cancel(with: .goingAway, reason: nil)

        // Asking again changes nothing.
        await host.setRunning(true, port: 0)
        #expect(host.server == server)
        await host.setRunning(false)
        #expect(!host.isRunning && host.server == nil)
    }

    @Test("A party is started at this Mac's own server while it runs, before any other")
    func partyUsesTheHost() async {
        let model = AppModel(dependencies: .ephemeral(http: StubHTTPClient(data: Data())))
        model.settings.settings.partyServer = "https://party.example.com"
        #expect(model.party.server?.url.host == "party.example.com")
        await model.partyHost.setRunning(true, port: 0)
        #expect(model.party.server == model.partyHost.server && model.party.server?.url.host == "127.0.0.1")
        await model.partyHost.setRunning(false)
        #expect(model.party.server?.url.host == "party.example.com")
    }

    @Test("The Mac that runs the server reaches it without going onto the network; others are told what macOS may be blocking")
    func reachingTheServer() throws {
        let nearby = try #require(PartyServer("http://192.168.178.188:8787"))
        // Same server, same port and path, by the loopback interface: no permission is needed for that.
        #expect(nearby.socketURLOnThisMachine.absoluteString == "ws://127.0.0.1:8787/ws")
        #expect(nearby.isOnLocalNetwork)
        let hosted = try #require(PartyServer("https://party.example.com"))
        #expect(!hosted.isOnLocalNetwork && PartyServer("http://127.0.0.1:8787")?.isOnLocalNetwork == false)

        let hint = PartyCenter.localNetworkHint(server: nearby, connection: .connecting, appName: "Nebula")
        #expect(hint?.contains("Privacy & Security › Local Network") == true && hint?.contains("Nebula") == true)
        #expect(PartyCenter.localNetworkHint(server: nearby, connection: .reconnecting, appName: "Nebula") != nil)
        // Nothing to say once it works, or about a server that is not on the local network.
        #expect(PartyCenter.localNetworkHint(server: nearby, connection: .connected, appName: "Nebula") == nil)
        #expect(PartyCenter.localNetworkHint(server: hosted, connection: .connecting, appName: "Nebula") == nil)
    }

    @Test("Settings says what a typed server address comes to")
    func footnote() {
        #expect(PartySettingsPane.serverFootnote(typed: "ftp://x", isHosting: false).hasPrefix("That is not an address"))
        #expect(PartySettingsPane.serverFootnote(typed: "http://192.168.1.20:8787", isHosting: false).hasPrefix("The party server lets"))
        #expect(PartySettingsPane.serverFootnote(typed: "", isHosting: true) == "Not used while this Mac runs a server of its own.")
        #expect(SettingsTab.allCases.map(\.title) == ["General", "Account", "Playback", "Streaming", "Watch Party", "Shortcuts", "Advanced"])
    }
}

@MainActor
@Suite("Whether macOS lets the app onto the local network")
struct LocalNetworkGateTests {
    /// Answers in turn, and counts how often it was asked.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [LocalNetworkAccess.Answer]
        private(set) var asked = 0

        init(_ answers: [LocalNetworkAccess.Answer]) {
            remaining = answers
        }

        func next() -> LocalNetworkAccess.Answer {
            lock.withLock {
                asked += 1
                return remaining.isEmpty ? .unknown : remaining.removeFirst()
            }
        }

        var count: Int {
            lock.withLock { asked }
        }
    }

    @Test("A refusal is said, with the way to the switch; asking again notices that the switch was flipped")
    func deniedThenAllowed() async {
        let answers = Answers([.denied, .allowed])
        var opened = 0
        let gate = LocalNetworkGate(check: { answers.next() }, openSettings: { opened += 1 })
        #expect(gate.state == .unknown && LocalNetworkGate.message(for: gate.state, appName: "Nebula") == nil)

        gate.refresh()
        // While macOS may be asking, the user is told what to answer.
        #expect(gate.state == .checking)
        #expect(LocalNetworkGate.message(for: .checking, appName: "Nebula")?.contains("choose Allow") == true)
        // Asked once, however often the screens that care come and go.
        gate.refresh()
        await gate.waitForCheck()
        #expect(gate.state == .denied && answers.count == 1)
        let message = LocalNetworkGate.message(for: .denied, appName: "Nebula")
        #expect(message?.contains("Privacy & Security › Local Network") == true && message?.contains("Nebula") == true)

        gate.showSystemSettings()
        #expect(opened == 1)

        gate.refresh()
        await gate.waitForCheck()
        #expect(gate.state == .allowed && LocalNetworkGate.message(for: .allowed, appName: "Nebula") == nil)
    }

    @Test("No answer is no claim; and what was allowed stays allowed while it is looked into again")
    func unknownAnswers() async {
        let answers = Answers([.unknown, .allowed, .unknown])
        let gate = LocalNetworkGate(check: { answers.next() })
        gate.refresh()
        await gate.waitForCheck()
        #expect(gate.state == .unknown)
        gate.refresh()
        await gate.waitForCheck()
        #expect(gate.state == .allowed)
        gate.refresh()
        // Not back to "checking": nothing has taken the permission away.
        #expect(gate.state == .allowed)
        await gate.waitForCheck()
        #expect(gate.state == .allowed)
    }

    @Test("A check or a test never asks macOS about the network")
    func neverAsksInChecks() async {
        let gate = LocalNetworkGate(check: nil)
        gate.refresh()
        await gate.waitForCheck()
        #expect(gate.state == .unknown)
        // The app as tests and scratch profiles make it keeps to this machine.
        let model = AppModel(dependencies: .ephemeral(http: StubHTTPClient(data: Data())))
        model.localNetwork.refresh()
        await model.localNetwork.waitForCheck()
        #expect(model.localNetwork.state == .unknown)
        #expect(model.party.localNetwork === model.localNetwork && model.partyHost.localNetwork === model.localNetwork)
    }

    @Test("The check's Bonjour type is one the system accepts: short, and listed in the app's Info.plist")
    func serviceType() throws {
        let type = LocalNetworkAccess.serviceType
        #expect(type.hasPrefix("_") && type.hasSuffix("._tcp"))
        // A service's name is at most fifteen characters.
        #expect(type.dropFirst().dropLast("._tcp".count).count <= 15)
        let plist = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        #expect((info["NSBonjourServices"] as? [String])?.contains(type) == true)
        #expect((info["NSLocalNetworkUsageDescription"] as? String)?.isEmpty == false)
    }
}
