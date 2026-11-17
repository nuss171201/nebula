import PlayerKit
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

/// The File menu's commands for opening media, and the Playback menu.
///
/// The Playback menu's items carry no keyboard shortcuts: keys are handled by the player
/// window through its own (changeable) bindings, and a menu shortcut without a modifier,
/// such as Space, would also fire while typing in a text field elsewhere in the app.
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

        CommandMenu("Playback") {
            Group {
                item("Play / Pause", .togglePause)
                Divider()
                item("Forward 5 Seconds", .seekBy(5))
                item("Back 5 Seconds", .seekBy(-5))
                item("Forward 30 Seconds", .seekBy(30))
                item("Back 30 Seconds", .seekBy(-30))
                item("Next Frame", .stepFrameForward)
                item("Previous Frame", .stepFrameBackward)
                Divider()
                item("Next Chapter", .nextChapter)
                item("Previous Chapter", .previousChapter)
                item("Next in Queue", .playNext)
                item("Previous in Queue", .playPrevious)
                Divider()
                Menu("Speed") {
                    item("Faster", .speedUp)
                    item("Slower", .slowDown)
                    item("Normal Speed", .resetSpeed)
                }
                item("Set A-B Loop Point", .cycleABLoop)
            }
            Group {
                Divider()
                item("Volume Up", .changeVolumeBy(5))
                item("Volume Down", .changeVolumeBy(-5))
                item("Mute", .toggleMute)
                item("Next Audio Track", .cycleTrack(.audio))
                item("Next Subtitle Track", .cycleTrack(.subtitle))
                item("Show or Hide Subtitles", .toggleSubtitles)
                Divider()
                item("Save Screenshot", .screenshot(includingSubtitles: true))
                item("Save Screenshot Without Subtitles", .screenshot(includingSubtitles: false))
                Divider()
                item("Full Screen", .toggleFullScreen)
                item("Picture in Picture", .togglePictureInPicture)
                item("Mini Player", .toggleMiniPlayer)
                item("Always on Top", .toggleAlwaysOnTop)
            }
            .disabled(!model.player.isPlayerOpen)
        }
    }

    private func item(_ title: String, _ command: PlayerCommand) -> some View {
        Button(title) {
            model.player.perform(command)
        }
    }
}
