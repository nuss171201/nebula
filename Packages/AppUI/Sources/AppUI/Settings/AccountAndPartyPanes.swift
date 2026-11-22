import AppKit
import SwiftUI
import WatchParty

/// Settings › Account: create an account, log in, log out.
struct AccountSettingsPane: View {
    /// `nil` where the app has no account model (previews, some tests).
    let center: AccountCenter?

    var body: some View {
        Form {
            if let center {
                switch center.phase {
                case .unavailable:
                    Section("Account") {
                        Label("Accounts are not set up in this build.", systemImage: "person.crop.circle.badge.exclamationmark")
                        Text("Whoever builds the app names a sign-in service in its configuration. Nothing else in the app depends on having an account.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case let .signedIn(email):
                    SignedInSection(center: center, email: email)
                case .signedOut:
                    AccountForm(center: center)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SignedInSection: View {
    let center: AccountCenter
    let email: String

    var body: some View {
        Section {
            LabeledContent("Logged in as") {
                Text(email)
                    .textSelection(.enabled)
            }
            Button("Log Out") {
                Task { await center.logOut() }
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Your library, history and downloads stay on this Mac; an account does not move them anywhere yet.")
        }
    }
}

private struct AccountForm: View {
    @Bindable var center: AccountCenter

    var body: some View {
        Section {
            Picker("Account", selection: $center.mode) {
                ForEach(AccountCenter.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Email", text: $center.email, prompt: Text("you@example.com"))
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Password", text: $center.password, prompt: Text(passwordPrompt))
                .textContentType(center.mode == .signUp ? .newPassword : .password)
                .onSubmit(submit)
            HStack {
                Button(center.mode.title, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!center.canSubmit)
                if center.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if center.mode == .logIn {
                    Button("Forgot Password…") {
                        Task { await center.sendPasswordReset() }
                    }
                    .buttonStyle(.link)
                    .disabled(center.isBusy)
                }
            }
        } header: {
            Text("Account")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error = center.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let notice = center.notice {
                    Label(notice, systemImage: "envelope")
                }
                Text("Your library, history and downloads stay on this Mac whether or not you have an account.")
            }
        }
    }

    private var passwordPrompt: String {
        center.mode == .signUp ? "At least \(AccountCenter.minimumPasswordLength) characters" : "Password"
    }

    private func submit() {
        Task { await center.submit() }
    }
}

/// Settings › Watch Party: who you are in a party, and where parties are started.
struct PartySettingsPane: View {
    @Bindable var model: SettingsModel
    let host: PartyHost?

    var body: some View {
        Form {
            Section("You") {
                TextField("Your name", text: $model.settings.partyName, prompt: Text(PartyCenter.defaultName))
            }
            if let host {
                Section {
                    Toggle("Run a Party Server on This Mac", isOn: $model.settings.hostsPartyServer)
                    if let server = host.server {
                        LabeledContent("Address") {
                            HStack(spacing: 8) {
                                Text(server.url.absoluteString)
                                    .monospaced()
                                    .textSelection(.enabled)
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(server.url.absoluteString, forType: .string)
                                }
                            }
                        }
                    } else if host.isStarting {
                        ProgressView()
                            .controlSize(.small)
                    }
                } header: {
                    Text("Server on This Mac")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem = host.problem {
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Text(host.reachNote)
                    }
                }
            }
            Section {
                TextField("Party server", text: $model.settings.partyServer, prompt: Text("https://…"))
                    .autocorrectionDisabled()
                    .disabled(host?.isRunning == true)
            } header: {
                Text("Server Somewhere Else")
            } footer: {
                Text(Self.serverFootnote(typed: model.settings.partyServer, isHosting: host?.isRunning == true))
            }
        }
        .formStyle(.grouped)
    }

    /// What the party server is, and whether what was typed can be used as one.
    nonisolated static func serverFootnote(typed: String, isHosting: Bool) -> String {
        if isHosting {
            return "Not used while this Mac runs a server of its own."
        }
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, PartyServer(typed) == nil {
            return "That is not an address that can be used: it has to start with https:// (or http:// for an address on your own network)."
        }
        return """
        The party server lets the apps in a party find each other; what they say then goes directly between them. \
        Leave it empty to use the one this app came with, if it came with one. An invitation link always names its own.
        """
    }
}
