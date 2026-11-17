import AppKit
import PlayerKit
import SwiftUI

/// The player's keyboard shortcuts: every action with its keys; add one by pressing it.
struct ShortcutsSettingsPane: View {
    @Bindable var model: ShortcutsModel
    @State private var recorder = KeyRecorder()

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.groups) { group in
                    Section(group.title) {
                        ForEach(group.rows) { row in
                            ShortcutRow(model: model, row: row)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Restore Defaults") { model.resetAll() }
                    .disabled(!model.hasChanges)
            }
            .padding(12)
        }
        .onChange(of: model.recordingActionID, initial: true) { _, id in
            if id == nil {
                recorder.stop()
            } else {
                recorder.start { chord in
                    model.record(chord)
                }
            }
        }
        .onDisappear {
            model.recordingActionID = nil
            recorder.stop()
        }
    }

    private var statusText: String {
        if model.recordingActionID != nil {
            return "Press the keys for the shortcut, or Esc to cancel."
        }
        return model.notice ?? "These work in the player window."
    }
}

private struct ShortcutRow: View {
    let model: ShortcutsModel
    let row: ShortcutsModel.Row

    private var isRecording: Bool {
        model.recordingActionID == row.id
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(row.action.title)
            Spacer(minLength: 12)
            ForEach(row.chords, id: \.self) { chord in
                Button {
                    model.remove(chord)
                } label: {
                    HStack(spacing: 4) {
                        Text(chord.displayText)
                            .font(.callout.monospaced())
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Remove this shortcut")
                .accessibilityLabel("\(chord.spokenText), shortcut for \(row.action.title)")
                .accessibilityHint("Removes this shortcut")
            }
            Button {
                model.toggleRecording(for: row.action)
            } label: {
                Text(isRecording ? "Press Keys…" : "Add")
                    .frame(minWidth: 76)
            }
            .controlSize(.small)
            .accessibilityLabel(isRecording ? "Stop recording" : "Add a shortcut for \(row.action.title)")
            Button {
                model.reset(row.action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Put back the standard keys")
            .accessibilityLabel("Put back the standard keys for \(row.action.title)")
            .opacity(row.isChanged ? 1 : 0)
            .disabled(!row.isChanged)
        }
    }
}

/// Catches the next key presses in the app while a shortcut is being recorded, so that they
/// reach the editor instead of the focused control or a menu.
@MainActor
final class KeyRecorder {
    private var monitor: Any?

    func start(_ handler: @escaping @MainActor (KeyChord) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let chord = KeyChord(
                keyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers,
                modifierFlags: event.modifierFlags
            ) else {
                // A key that cannot be bound (Tab, a function key) goes where it was going.
                return event
            }
            // Event monitors are called on the main thread.
            MainActor.assumeIsolated {
                handler(chord)
            }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
