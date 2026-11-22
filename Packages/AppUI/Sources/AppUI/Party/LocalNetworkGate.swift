import AppKit
import Foundation
import Observation
import os
import SwiftUI
import WatchParty

/// What is known about whether macOS lets the app onto the local network, which a watch
/// party between Macs on one network cannot do without, and the way to the switch.
@MainActor
@Observable
public final class LocalNetworkGate {
    public enum State: Sendable, Equatable {
        /// Not looked into yet.
        case unknown
        /// Finding out; macOS may be asking the user at this moment.
        case checking
        case allowed
        case denied
    }

    public private(set) var state = State.unknown

    @ObservationIgnored private let check: (@Sendable () async -> LocalNetworkAccess.Answer)?
    @ObservationIgnored private let openSettings: @MainActor () -> Void
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - check: Finds out; `nil` never looks, for checks and tests that must not make macOS
    ///     ask about the network.
    ///   - openSettings: Shows the system's Local Network switches.
    public init(
        check: (@Sendable () async -> LocalNetworkAccess.Answer)?,
        logSubsystem: String = "party",
        openSettings: (@MainActor () -> Void)? = nil
    ) {
        self.check = check
        logger = Logger(subsystem: logSubsystem, category: "party")
        self.openSettings = openSettings ?? Self.openSystemSettings
    }

    /// The real thing, unless the app keeps to this machine: then it never looks.
    public convenience init(staysOnThisMachine: Bool, logSubsystem: String) {
        if staysOnThisMachine {
            self.init(check: nil, logSubsystem: logSubsystem)
        } else {
            self.init(check: { await LocalNetworkAccess.check() }, logSubsystem: logSubsystem)
        }
    }

    /// Finds out, unless it is being found out already. Asking again after a refusal is how
    /// the app notices that the user has since flipped the switch.
    public func refresh() {
        guard let check, task == nil else { return }
        if state != .allowed {
            state = .checking
        }
        task = Task { [weak self] in
            let answer = await check()
            guard let self else { return }
            task = nil
            switch answer {
            case .allowed: state = .allowed
            case .denied: state = .denied
            // No answer: say nothing rather than guess.
            case .unknown: state = state == .checking ? .unknown : state
            }
            logger.notice("local network access: \(String(describing: answer), privacy: .public)")
        }
    }

    /// Waits for a check that is under way. For tests.
    func waitForCheck() async {
        await task?.value
    }

    /// Shows the system's Local Network switches.
    public func showSystemSettings() {
        openSettings()
    }

    /// What to tell the user, if anything.
    public nonisolated static func message(for state: State, appName: String) -> String? {
        switch state {
        case .unknown, .allowed:
            nil
        case .checking:
            "Checking whether macOS lets \(appName) use the local network. If it asks, choose Allow."
        case .denied:
            """
            macOS is keeping \(appName) off the local network, so Macs on this network cannot reach each other. \
            Switch \(appName) on under Privacy & Security › Local Network, then check again.
            """
        }
    }

    private static func openSystemSettings() {
        // The pane's address on current systems, then the one older systems know.
        let addresses = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
        ]
        for address in addresses {
            if let url = URL(string: address), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

/// The gate's message with its two buttons, wherever it is shown.
struct LocalNetworkNotice: View {
    let gate: LocalNetworkGate
    let appName: String

    var body: some View {
        if let message = LocalNetworkGate.message(for: gate.state, appName: appName) {
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: gate.state == .denied ? "exclamationmark.triangle" : "wifi")
                    .foregroundStyle(gate.state == .denied ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if gate.state == .denied {
                    HStack {
                        Button("Open Local Network Settings…", action: gate.showSystemSettings)
                        Button("Check Again", action: gate.refresh)
                    }
                }
            }
            .font(.caption)
        }
    }
}
