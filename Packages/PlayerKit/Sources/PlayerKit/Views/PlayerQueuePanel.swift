import SwiftUI

/// The side panel listing what is queued: click to play, drag to reorder, remove, and repeat.
struct PlayerQueuePanel: View {
    @Bindable var model: PlayerModel
    let chrome: PlayerChromeModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                Button {
                    chrome.isQueueVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Queue")
            }
            .padding(12)

            Divider()

            if model.state.playlist.isEmpty {
                ContentUnavailableView("Nothing Queued", systemImage: "list.bullet", description: Text("Open several files, or a folder, to fill the queue."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.state.playlist) { entry in
                        QueueRow(entry: entry) {
                            model.play(queueIndex: entry.index)
                        } remove: {
                            model.removeFromQueue(at: entry.index)
                        }
                    }
                    .onMove { offsets, destination in
                        // The engine moves one entry at a time; the list only ever drags one.
                        if let index = offsets.first {
                            model.moveQueueEntry(from: index, toBefore: destination)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Divider()

            Picker("Repeat", selection: $model.repeatMode) {
                ForEach(RepeatMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .padding(12)
        }
        .frame(width: PlayerSettingsPanel.width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .controlSize(.small)
    }
}

private struct QueueRow: View {
    let entry: PlaylistEntry
    let play: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill")
                .font(.caption2)
                .opacity(entry.isCurrent ? 1 : 0)
                .accessibilityHidden(true)
            Button(action: play) {
                Text(entry.displayName)
                    .fontWeight(entry.isCurrent ? .semibold : .regular)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isCurrent ? "\(entry.displayName), playing" : entry.displayName)
            .accessibilityHint("Plays this item")

            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(entry.displayName) from the Queue")
        }
        .padding(.vertical, 2)
    }
}
