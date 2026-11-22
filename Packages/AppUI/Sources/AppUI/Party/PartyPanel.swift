import SwiftUI
import WatchParty

/// The party's panel in the player window: who is here, what the party is doing, and the chat.
/// Before there is a party, the way to start or join one.
struct PartyPanel: View {
    let center: PartyCenter

    var body: some View {
        Group {
            if let session = center.session {
                PartySessionView(center: center, session: session)
            } else {
                ScrollView {
                    PartySetupView(center: center, isCompact: true)
                        .padding(12)
                }
            }
        }
        .onAppear { center.panelIsShowing(true) }
        .onDisappear { center.panelIsShowing(false) }
    }
}

private struct PartySessionView: View {
    let center: PartyCenter
    let session: PartySession
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                PartyNotices(center: center, session: session)
                ForEach(session.people) { person in
                    PersonRow(person: person)
                }
                PartyActions(center: center, session: session)
            }
            .padding(12)

            Divider()

            ChatList(entries: session.chat, me: session.me)

            Divider()

            HStack(spacing: 8) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .accessibilityLabel("Message to the party")
                Button("Send", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }

    private func send() {
        session.send(draft)
        draft = ""
    }
}

/// What needs saying above the list of people: the state of the connection, what the party is
/// watching if this player is not on it, who is being waited for, and the last problem.
struct PartyNotices: View {
    let center: PartyCenter
    let session: PartySession

    var body: some View {
        if let text = Self.connectionText(session.connection) {
            Label(text, systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if session.invite.server.isOnLocalNetwork, let gate = center.localNetwork, gate.state != .unknown {
            LocalNetworkNotice(gate: gate, appName: center.appName)
        } else if let hint = PartyCenter.localNetworkHint(server: session.invite.server, connection: session.connection, appName: center.appName) {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if session.isElsewhere, let content = session.content {
            VStack(alignment: .leading, spacing: 4) {
                Text("The party is watching \(content.title).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if content.catalog != nil {
                    Button("Show It", action: center.openPartyContent)
                        .accessibilityHint("Opens its page in the main window, where you choose a stream")
                } else {
                    Text("Open your own copy to watch along.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if session.content == nil {
            Text(session.canControl ? "Play something and the party watches it with you." : "Nothing is playing yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let name = session.waitingFor {
            Label("Waiting for \(name)…", systemImage: "hourglass")
                .font(.callout)
        }
        if let message = center.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func connectionText(_ connection: PartySession.Connection) -> String? {
        switch connection {
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting to the party server. People already here stay connected."
        case .connected, .ended, .failed: nil
        }
    }
}

private struct PersonRow: View {
    let person: PartySession.Person

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(for: person.activity))
                .foregroundStyle(person.activity == .ready ? .green : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(person.isMe ? "\(person.name) (you)" : person.name)
                    .fontWeight(person.isMe ? .semibold : .regular)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if person.inVoice {
                Image(systemName: person.isMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(person.isMuted ? .secondary : .primary)
                    .accessibilityLabel(person.isMuted ? "In the voice chat, muted" : "In the voice chat")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let activity = PartyText.describe(person.activity, otherTitle: person.otherTitle)
        return person.isHost ? "Host · " + activity : activity
    }

    static func symbol(for activity: MemberStatus.Activity) -> String {
        switch activity {
        case .ready: "checkmark.circle.fill"
        case .catchingUp: "arrow.triangle.2.circlepath"
        case .stalled: "hourglass"
        case .away: "moon.zzz"
        }
    }
}

/// Words the party's views share.
enum PartyText {
    static func describe(_ activity: MemberStatus.Activity, otherTitle: String?) -> String {
        switch activity {
        case .ready: "Watching"
        case .catchingUp: "Catching up"
        case .stalled: "Buffering"
        case .away: otherTitle.map { "Watching \($0)" } ?? "Not watching yet"
        }
    }

    static func people(_ count: Int) -> String {
        count == 1 ? "Only you so far" : "\(count) people"
    }
}

/// Invitation, voice, who controls, and leaving.
private struct PartyActions: View {
    let center: PartyCenter
    let session: PartySession

    var body: some View {
        HStack(spacing: 8) {
            Button(center.didCopyInvite ? "Link Copied" : "Copy Invitation", action: center.copyInvite)
                .help("Copies the link to send to friends")
            Spacer(minLength: 0)
            if center.allowsVoice {
                if session.inVoice {
                    Button(action: center.toggleMute) {
                        Image(systemName: session.isMuted ? "mic.slash.fill" : "mic.fill")
                    }
                    .accessibilityLabel(session.isMuted ? "Unmute Microphone" : "Mute Microphone")
                    .help(session.isMuted ? "Unmute" : "Mute")
                }
                Button(session.inVoice ? "Leave Voice" : "Join Voice") {
                    Task { await center.toggleVoice() }
                }
                .help("Talk with the others. Headphones keep the film's sound out of your microphone.")
            }
        }
        if session.isHost {
            Toggle("Everyone can pause and seek", isOn: Binding {
                session.everyoneControls
            } set: { everyone in
                session.setEveryoneControls(everyone)
            })
        } else if !session.canControl {
            Text("The host controls playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button("Leave Party", role: .destructive, action: center.leave)
    }
}

/// The chat, newest at the bottom and kept in view.
private struct ChatList: View {
    let entries: [PartyCore.ChatEntry]
    let me: MemberID

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        ChatRow(entry: entry, me: me)
                            .id(entry.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: entries.last?.id, initial: true) { _, last in
                if let last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityLabel("Party chat")
    }
}

private struct ChatRow: View {
    let entry: PartyCore.ChatEntry
    let me: MemberID

    var body: some View {
        switch entry.kind {
        case .event:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        case let .message(author, name):
            VStack(alignment: .leading, spacing: 1) {
                Text(author == me ? "You" : name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(author == me ? .secondary : .primary)
                Text(entry.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
