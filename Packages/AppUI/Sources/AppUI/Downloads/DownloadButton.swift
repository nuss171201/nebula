import AppKit
import SwiftUI

/// Keeps a video for watching without a connection, and says how that is going: Download,
/// then a ring that fills, then Downloaded.
struct DownloadButton: View {
    /// The video's download, if it has one.
    let item: DownloadItem?
    /// Starts one; `nil` when nothing here can be downloaded.
    let start: (() -> Void)?
    let center: DownloadCenter

    var body: some View {
        if let item {
            Button {
                act(on: item)
            } label: {
                label(for: item)
            }
            .buttonStyle(PillButtonStyle(isOn: item.stage != .failed))
            .help(item.statusLine)
            .accessibilityValue(item.statusLine)
            .contextMenu {
                if item.stage == .finished, let file = item.fileURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                }
                Button(item.stage == .finished ? "Move to Trash" : "Remove Download", role: .destructive) {
                    center.remove(item.id)
                }
            }
        } else if let start {
            Button(action: start) {
                Label("Download", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(PillButtonStyle())
            .help("Keeps this for watching without a connection")
        }
    }

    /// Pressing it does the next sensible thing: pause what runs, carry on with what is
    /// paused, try again what failed, show what is there.
    private func act(on item: DownloadItem) {
        switch item.stage {
        case .queued: center.pause(item.id)
        case .paused, .failed: center.resume(item.id)
        case .finished:
            if let file = item.fileURL {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
    }

    @ViewBuilder
    private func label(for item: DownloadItem) -> some View {
        switch item.stage {
        case .finished:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
        case .failed:
            Label("Try Download Again", systemImage: "exclamationmark.arrow.circlepath")
        case .paused:
            Label(Self.percent(item).map { "Paused · \($0)" } ?? "Paused", systemImage: "pause.fill")
        case .queued:
            HStack(spacing: 7) {
                ZStack {
                    Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(item.fraction ?? 0, 0.03))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.5), value: item.fraction)
                }
                .frame(width: 14, height: 14)
                Text(Self.percent(item) ?? (item.activity == nil ? "Waiting" : "Starting"))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
    }

    static func percent(_ item: DownloadItem) -> String? {
        item.fraction.map { "\(Int(($0 * 100).rounded(.down))) %" }
    }
}
