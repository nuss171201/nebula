import Foundation
import MediaCore

/// Where accounts are kept: a hosted sign-in service (a Supabase project), named by its address
/// and the public key every app of the project carries. The key is not a secret; it only says
/// which project is being spoken to.
public struct AccountConfiguration: Sendable, Equatable {
    public let url: URL
    public let publicKey: String

    /// Accepts an `https` address with a host and a key; `http` only for this machine, which is
    /// what tests use. Anything else is no configuration, and the app then has no accounts.
    public init?(address: String, publicKey: String) {
        let key = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty, !key.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        let scheme = components.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost"].contains(host)) else { return nil }
        var base = components
        base.query = nil
        base.fragment = nil
        base.path = ""
        guard let url = base.url else { return nil }
        self.url = url
        self.publicKey = key
    }

    /// The Info.plist keys the configuration is read from (`ACCOUNT_SERVER_URL` and
    /// `ACCOUNT_PUBLIC_KEY` in `Config/Branding.xcconfig`).
    public static let addressInfoKey = "AccountServerURL"
    public static let publicKeyInfoKey = "AccountPublicKey"

    public init?(infoDictionary: [String: Any]?) {
        guard let address = infoDictionary?[Self.addressInfoKey] as? String,
              let key = infoDictionary?[Self.publicKeyInfoKey] as? String
        else { return nil }
        self.init(address: address, publicKey: key)
    }
}

/// Being signed in: who, and the tokens that prove it for a while.
public struct AccountSession: Sendable, Equatable, Codable {
    public var userID: String
    public var email: String
    var accessToken: String
    var refreshToken: String
    /// When the access token stops being accepted.
    var expiresAt: Date

    /// Whether the access token is past, or nearly past, its time.
    func needsRefresh(now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < 120
    }
}

public enum AccountError: Error, Sendable, Equatable {
    case wrongEmailOrPassword
    case emailNotConfirmed
    case alreadyRegistered
    case weakPassword
    case invalidEmail
    case tooManyAttempts
    /// The session is no longer accepted: sign in again.
    case sessionExpired
    /// The service could not be reached.
    case offline
    /// Anything else, in the service's own words where it gave any.
    case service(String)

    public var userMessage: String {
        switch self {
        case .wrongEmailOrPassword: "That email and password do not match an account."
        case .emailNotConfirmed: "This email has not been confirmed yet. Open the link in the message that was sent to it, then log in."
        case .alreadyRegistered: "There is already an account with this email. Log in instead."
        case .weakPassword: "That password is too easy to guess. Use at least eight characters."
        case .invalidEmail: "That does not look like an email address."
        case .tooManyAttempts: "Too many attempts. Wait a little and try again."
        case .sessionExpired: "You have been logged out. Log in again."
        case .offline: "The account service could not be reached. Check your internet connection."
        case let .service(message): message.isEmpty ? "The account service answered with an error." : message
        }
    }

    /// Whether the service itself said no, as against not being reached.
    var isRefusal: Bool {
        self != .offline
    }
}

/// What signing up comes to.
public enum SignUpOutcome: Sendable, Equatable {
    case signedIn(AccountSession)
    /// The account exists once the link in the confirmation email has been opened.
    case confirmationSent
}

/// Speaks to the sign-in service: creating an account, logging in and out, keeping a session
/// alive, and asking for a password reset. Nothing here remembers anything.
public struct AccountClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let configuration: AccountConfiguration
    private let transport: Transport
    private let retryPolicy: RetryPolicy
    private let now: @Sendable () -> Date

    /// - Parameter transport: Sends a request; `URLSession` by default, a stand-in in tests.
    public init(
        configuration: AccountConfiguration,
        retryPolicy: RetryPolicy = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        transport: Transport? = nil
    ) {
        self.configuration = configuration
        self.retryPolicy = retryPolicy
        self.now = now
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    public func signUp(email: String, password: String) async throws(AccountError) -> SignUpOutcome {
        let data = try await post("signup", body: ["email": email, "password": password])
        if let session = Self.session(from: data, now: now()) {
            return .signedIn(session)
        }
        return .confirmationSent
    }

    public func logIn(email: String, password: String) async throws(AccountError) -> AccountSession {
        let data = try await post("token", query: "grant_type=password", body: ["email": email, "password": password])
        guard let session = Self.session(from: data, now: now()) else { throw .service("") }
        return session
    }

    /// A fresh session for one that is running out.
    public func refresh(_ session: AccountSession) async throws(AccountError) -> AccountSession {
        let data: Data
        do throws(AccountError) {
            data = try await post("token", query: "grant_type=refresh_token", body: ["refresh_token": session.refreshToken])
        } catch {
            // A refusal here means the session is over, whatever words the service used.
            throw error.isRefusal ? .sessionExpired : error
        }
        guard let fresh = Self.session(from: data, now: now()) else { throw .sessionExpired }
        return fresh
    }

    /// Ends the session at the service. Being offline is no reason not to forget it here.
    public func logOut(_ session: AccountSession) async {
        _ = try? await post("logout", body: [:], bearer: session.accessToken)
    }

    /// Has a message sent with a link for choosing a new password.
    public func sendPasswordReset(email: String) async throws(AccountError) {
        _ = try await post("recover", body: ["email": email])
    }

    // MARK: - Requests

    private func post(_ path: String, query: String? = nil, body: [String: String], bearer: String? = nil) async throws(AccountError) -> Data {
        var components = URLComponents(url: configuration.url.appendingPathComponent("auth/v1/\(path)"), resolvingAgainstBaseURL: false)
        components?.query = query
        guard let url = components?.url, let payload = try? JSONEncoder().encode(body) else { throw .service("") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publicKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer ?? configuration.publicKey)", forHTTPHeaderField: "Authorization")

        var attempt = 1
        while true {
            do {
                let (data, response) = try await transport(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200 ..< 300).contains(status) else { throw Self.error(status: status, data: data) }
                return data
            } catch let error as AccountError {
                throw error
            } catch {
                // Only when the request cannot have arrived: asking twice for the same account
                // to be made would have the second answer say it already exists.
                let neverArrived = (error as? URLError).map { Self.neverArrivedCodes.contains($0.code) } ?? false
                guard neverArrived, !Task.isCancelled, let delay = retryPolicy.delay(beforeRetry: attempt) else { throw .offline }
                attempt += 1
                try? await Task.sleep(for: delay)
            }
        }
    }

    private static let neverArrivedCodes: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]

    // MARK: - Reading answers

    private struct SessionAnswer: Decodable {
        struct User: Decodable {
            let id: String
            let email: String?
        }

        let accessToken: String
        let refreshToken: String
        let expiresIn: Double?
        let user: User
    }

    private struct ErrorAnswer: Decodable {
        let errorCode: String?
        let error: String?
        let msg: String?
        let message: String?
        let errorDescription: String?
    }

    /// The service writes its keys with underscores.
    private static var snakeCaseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func session(from data: Data, now: Date) -> AccountSession? {
        guard let answer = try? snakeCaseDecoder.decode(SessionAnswer.self, from: data), !answer.accessToken.isEmpty else { return nil }
        return AccountSession(
            userID: answer.user.id,
            email: answer.user.email ?? "",
            accessToken: answer.accessToken,
            refreshToken: answer.refreshToken,
            expiresAt: now.addingTimeInterval(answer.expiresIn ?? 3600)
        )
    }

    /// What a refusal means, from the service's code for it where it gives one and from its
    /// words where it does not (older versions answer with a sentence only).
    static func error(status: Int, data: Data) -> AccountError {
        let answer = try? snakeCaseDecoder.decode(ErrorAnswer.self, from: data)
        let words = answer?.msg ?? answer?.errorDescription ?? answer?.message ?? ""
        let lowered = words.lowercased()
        switch answer?.errorCode ?? answer?.error ?? "" {
        case "invalid_credentials": return .wrongEmailOrPassword
        case "invalid_grant" where !lowered.contains("confirm"): return .wrongEmailOrPassword
        case "email_not_confirmed": return .emailNotConfirmed
        case "user_already_exists", "email_exists": return .alreadyRegistered
        case "weak_password": return .weakPassword
        case "email_address_invalid": return .invalidEmail
        case "validation_failed" where lowered.contains("email"): return .invalidEmail
        case "over_request_rate_limit", "over_email_send_rate_limit": return .tooManyAttempts
        default: break
        }
        if status == 429 {
            return .tooManyAttempts
        }
        if lowered.contains("not confirmed") {
            return .emailNotConfirmed
        }
        if lowered.contains("already registered") {
            return .alreadyRegistered
        }
        if lowered.contains("invalid login") {
            return .wrongEmailOrPassword
        }
        return .service(String(words.prefix(200)))
    }
}
