import SwiftUI
import WatchParty

/// Along the bottom of the main window while a party is on: how it stands, and the things one
/// might want to do about it without the player open.
struct PartyStatusBar: View {
    let center: PartyCenter

    var body: some View {
        if let session = center.session {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Watch Party · \(PartyText.people(session.people.count))")
                        .font(.callout.weight(.medium))
                    Text(Self.detail(for: session, didCopy: center.didCopyInvite))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if session.isElsewhere, session.content?.catalog != nil {
                    Button("Show It", action: center.openPartyContent)
                }
                Button("Copy Invitation", action: center.copyInvite)
                Button("Leave", action: center.leave)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }

    static func detail(for session: PartySession, didCopy: Bool) -> String {
        if let text = PartyNotices.connectionText(session.connection) {
            return text
        }
        if didCopy {
            return "Invitation link copied. Send it to your friends."
        }
        if let content = session.content {
            return session.isElsewhere ? "The party is watching \(content.title)." : "Watching \(content.title)"
        }
        return session.canControl ? "Play something and the party watches it with you." : "Nothing is playing yet."
    }
}

/// Tells the party centre which window is the app's main one.
struct MainWindowReader: NSViewRepresentable {
    let center: PartyCenter

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        // The view has no window until it is in one.
        DispatchQueue.main.async { [weak view] in
            center.mainWindow = view?.window
        }
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        if let window = view.window {
            center.mainWindow = window
        }
    }
}

/// The File menu's party items.
public struct PartyCommands: Commands {
    private let center: PartyCenter

    public init(center: PartyCenter) {
        self.center = center
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            if center.session == nil {
                Button("Start or Join Watch Party…") {
                    center.errorMessage = nil
                    center.isSetupPresented = true
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            } else {
                Button("Copy Watch Party Invitation", action: center.copyInvite)
                Button("Leave Watch Party", action: center.leave)
            }
        }
    }
}
