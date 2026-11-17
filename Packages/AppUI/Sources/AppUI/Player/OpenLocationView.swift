import SwiftUI

/// The "Open Location" sheet: paste a web address (or a file path) to play it.
struct OpenLocationView: View {
    let coordinator: PlayerCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Location")
                .font(.headline)
            TextField("https://example.com/video.mp4", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(open)
                .onChange(of: address) {
                    coordinator.errorMessage = nil
                }
            if let message = coordinator.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                Text("Enter the address of a video or audio stream, or the path of a file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            coordinator.errorMessage = nil
            isFieldFocused = true
        }
    }

    private func open() {
        if coordinator.play(userInput: address) {
            dismiss()
        }
    }
}

/// File menu commands for opening media.
public struct PlaybackCommands: Commands {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open File…") {
                model.player.chooseFile()
            }
            .keyboardShortcut("o")

            Button("Open Location…") {
                model.player.isOpenLocationPresented = true
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}
