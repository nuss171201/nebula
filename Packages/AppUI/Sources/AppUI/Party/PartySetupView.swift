import SwiftUI

/// Starting a party or joining one with an invitation: the name the others will see, and the
/// two ways in. Shown as a sheet in the main window and inside the player's party panel.
struct PartySetupView: View {
    @Bindable var center: PartyCenter
    /// Leaves out the long explanations, for the narrow panel.
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 12 : 16) {
            if !isCompact {
                Text("Watch with friends, each on their own Mac. Everyone plays their own copy or stream; play, pause and jumps are shared.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Your name") {
                TextField("Your name", text: $center.displayName)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel("Your name in the party")
            }

            VStack(alignment: .leading, spacing: 6) {
                Button("Start a Watch Party") {
                    center.startParty()
                }
                .disabled(center.server == nil)
                Text(startHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Join with an invitation")
                    .font(isCompact ? .callout.weight(.medium) : .headline)
                HStack {
                    TextField("Paste the invitation link", text: $center.joinText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(center.joinParty)
                        .accessibilityLabel("Invitation link")
                    Button("Join", action: center.joinParty)
                        .disabled(center.joinText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let message = center.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var startHint: String {
        if center.server == nil {
            "No party server is set up. Start one or name one in Settings › Watch Party. You can still join a friend's party with their link."
        } else {
            "You get a link to send to your friends. It is copied for you."
        }
    }
}

/// The sheet in the main window.
struct PartySetupSheet: View {
    let center: PartyCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Watch Party")
                .font(.title2.weight(.semibold))
            PartySetupView(center: center)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    center.errorMessage = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
