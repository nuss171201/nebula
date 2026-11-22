import Foundation
import Observation

/// The user's account: creating one, logging in and out, and staying logged in between
/// launches. With no sign-in service configured for the build, there are no accounts.
@MainActor
@Observable
public final class AccountCenter {
    public enum Phase: Sendable, Equatable {
        /// The build names no sign-in service.
        case unavailable
        case signedOut
        case signedIn(email: String)
    }

    /// What the form is for.
    public enum Mode: String, Sendable, CaseIterable, Identifiable {
        case logIn, signUp

        public var id: Self { self }

        public var title: String {
            self == .logIn ? "Log In" : "Create Account"
        }
    }

    public private(set) var phase: Phase
    public private(set) var isBusy = false
    /// Good news to show under the form ("check your email").
    public private(set) var notice: String?
    public private(set) var errorMessage: String?
    public var mode = Mode.logIn {
        didSet { clearMessages() }
    }

    public var email = ""
    public var password = ""

    @ObservationIgnored private let client: AccountClient?
    @ObservationIgnored private let store: any AccountSessionStore
    @ObservationIgnored private var session: AccountSession?

    public static let minimumPasswordLength = 8

    /// - Parameter client: `nil` when the build names no sign-in service.
    public init(client: AccountClient?, store: any AccountSessionStore) {
        self.client = client
        self.store = store
        phase = client == nil ? .unavailable : .signedOut
    }

    public var isSignedIn: Bool {
        if case .signedIn = phase {
            true
        } else {
            false
        }
    }

    /// Whether the form has what it takes to be sent.
    public var canSubmit: Bool {
        !isBusy && Self.looksLikeEmail(email) && (mode == .logIn ? !password.isEmpty : password.count >= Self.minimumPasswordLength)
    }

    /// Picks up the session from last time, renewing it if it has run out. Call once, at launch.
    public func start() async {
        guard let client, let stored = store.load() else { return }
        session = stored
        phase = .signedIn(email: stored.email)
        guard stored.needsRefresh() else { return }
        do {
            try await adopt(client.refresh(stored))
        } catch .sessionExpired {
            forget()
            errorMessage = AccountError.sessionExpired.userMessage
        } catch {
            // Not reached: still the same person; the next launch tries again.
        }
    }

    /// Sends the form: logs in, or creates the account.
    public func submit() async {
        guard let client, canSubmit else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            switch mode {
            case .logIn:
                try await adopt(client.logIn(email: address, password: password))
            case .signUp:
                switch try await client.signUp(email: address, password: password) {
                case let .signedIn(session):
                    adopt(session)
                case .confirmationSent:
                    password = ""
                    mode = .logIn
                    notice = "Almost there: open the link in the message sent to \(address), then log in."
                }
            }
        } catch {
            errorMessage = error.userMessage
        }
    }

    public func logOut() async {
        guard let session else { return }
        forget()
        await client?.logOut(session)
    }

    /// Has a link for choosing a new password sent to the address in the form.
    public func sendPasswordReset() async {
        guard let client, !isBusy else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeEmail(address) else {
            errorMessage = "Enter your email address first."
            return
        }
        isBusy = true
        clearMessages()
        defer { isBusy = false }
        do {
            try await client.sendPasswordReset(email: address)
            notice = "If there is an account for \(address), a message with a link to choose a new password is on its way."
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func adopt(_ session: AccountSession) {
        self.session = session
        store.save(session)
        phase = .signedIn(email: session.email)
        // The password is not kept a moment longer than it is needed.
        password = ""
        clearMessages()
    }

    private func forget() {
        session = nil
        store.clear()
        phase = .signedOut
        password = ""
    }

    private func clearMessages() {
        notice = nil
        errorMessage = nil
    }

    /// Something before an @, something after it with a dot in it: enough to catch a slip,
    /// not a judgement on what addresses exist.
    nonisolated static func looksLikeEmail(_ text: String) -> Bool {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") else { return false }
        let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }
}
