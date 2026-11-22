import Foundation
import Network
import os

/// Finds out whether macOS lets this app onto the local network, asking the user if it has
/// never asked before.
///
/// macOS keeps an app off the local network until the user allows it, and tells the app
/// nothing: a refused connection looks like a network that is not there. The one place the
/// system does say "refused" is Bonjour, so the check advertises a service that means nothing
/// and looks for it. Finding it is permission; being told the policy forbids it is refusal.
/// Looking is also what puts the system's question on the screen the first time.
///
/// The service's type must be listed under `NSBonjourServices` in the app's Info.plist.
public enum LocalNetworkAccess {
    public enum Answer: Sendable, Equatable {
        case allowed
        case denied
        /// Nothing was learnt in time: the question may still be on the screen, or this Mac is
        /// on no network at all.
        case unknown
    }

    /// The Bonjour type the check advertises and looks for.
    public static let serviceType = "_partycheck._tcp"

    /// - Parameter timeout: How long to wait for the user's answer to the system's question.
    public static func check(timeout: Duration = .seconds(60)) async -> Answer {
        let queue = DispatchQueue(label: "local-network-access")
        guard let listener = try? NWListener(using: .tcp) else { return .unknown }
        let name = UUID().uuidString
        listener.service = NWListener.Service(name: name, type: serviceType)
        // Without a handler the listener refuses to start.
        listener.newConnectionHandler = { $0.cancel() }
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: NWParameters())
        let outcome = OSAllocatedUnfairLock<CheckedContinuation<Answer, Never>?>(initialState: nil)
        @Sendable func finish(_ answer: Answer) {
            let continuation = outcome.withLock { waiting in
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume(returning: answer)
        }

        let timer = Task {
            try? await Task.sleep(for: timeout)
            finish(.unknown)
        }
        defer {
            timer.cancel()
            listener.cancel()
            browser.cancel()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                outcome.withLock { $0 = continuation }
                browser.stateUpdateHandler = { state in
                    switch state {
                    case let .waiting(error), let .failed(error):
                        if case let .dns(code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                            finish(.denied)
                        }
                    default:
                        break
                    }
                }
                browser.browseResultsChangedHandler = { results, _ in
                    let found = results.contains { result in
                        if case let .service(found, _, _, _) = result.endpoint {
                            return found == name
                        }
                        return false
                    }
                    if found {
                        finish(.allowed)
                    }
                }
                listener.start(queue: queue)
                browser.start(queue: queue)
            }
        } onCancel: {
            finish(.unknown)
        }
    }
}
