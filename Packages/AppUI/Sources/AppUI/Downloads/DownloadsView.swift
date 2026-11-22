import AppKit
import SwiftUI

/// The Downloads section: every file being kept, with how it is coming along, and the
/// finished ones ready to play without a connection.
struct DownloadsView: View {
    let center: DownloadCenter
    /// Plays a finished download.
    let play: (DownloadItem) -> Void
    /// Opens the page of a download's title.
    let open: (DownloadItem) -> Void

    var body: some View {
        if center.items.isEmpty {
            ContentUnavailableView(
                "No Downloads",
                systemImage: "arrow.down.circle",
                description: Text("Use the Download button next to Play on a film's or an episode's page to keep it for watching without a connection.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SectionHeader(title: "Downloads", subtitle: Self.summary(of: center.items)) {
                        Button {
                            Self.showFolder(center.directory)
                        } label: {
                            Label("Show Folder", systemImage: "folder")
                        }
                        .buttonStyle(PillButtonStyle())
                        .help("Shows where downloaded files are kept")
                    }
                    let (pending, finished) = Self.sections(of: center.items)
                    if !pending.isEmpty {
                        group("In Progress", items: pending)
                    }
                    if !finished.isEmpty {
                        group("On This Mac", items: finished)
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 22)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(Theme.hover, value: center.items.map(\.id))
        }
    }

    private func group(_ title: String, items: [DownloadItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                DownloadRow(
                    item: item,
                    play: { play(item) },
                    open: { open(item) },
                    pause: { center.pause(item.id) },
                    resume: { center.resume(item.id) },
                    remove: { center.remove(item.id) }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// What is still on its way, in the order it will be fetched; then what is here, newest first.
    nonisolated static func sections(of items: [DownloadItem]) -> (pending: [DownloadItem], finished: [DownloadItem]) {
        (items.filter { $0.stage != .finished }, items.filter { $0.stage == .finished }.reversed())
    }

    /// "2 on this Mac · 1 on its way".
    nonisolated static func summary(of items: [DownloadItem]) -> String {
        let finished = items.count { $0.stage == .finished }
        let pending = items.count - finished
        let parts = [finished > 0 ? "\(finished) on this Mac" : nil, pending > 0 ? "\(pending) on \(pending == 1 ? "its" : "their") way" : nil]
        return parts.compactMap(\.self).joined(separator: " · ")
    }

    static func showFolder(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let play: () -> Void
    let open: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let remove: () -> Void

    @State private var isConfirmingRemoval = false

    private var isFinished: Bool {
        item.stage == .finished
    }

    var body: some View {
        HStack(spacing: 14) {
            // The row itself opens or plays; the buttons at its end are beside it, not inside
            // it, so that each is a button of its own to the keyboard and to VoiceOver.
            Button(action: isFinished ? play : open) {
                HStack(spacing: 14) {
                    artwork
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.video.titleName)
                            .font(.headline)
                            .lineLimit(1)
                        if let line = item.episodeLine {
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !isFinished, item.stage != .failed {
                            GradientProgressBar(fraction: item.fraction)
                                .opacity(item.stage == .paused ? 0.45 : 1)
                                .padding(.vertical, 2)
                        }
                        Text(item.statusLine)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(item.stage == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                        if !item.summary.isEmpty {
                            Text(item.summary)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if let fraction = item.fraction, !isFinished, item.stage != .failed {
                        Text("\(Int((fraction * 100).rounded(.down))) %")
                            .font(.title3.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                            .foregroundStyle(item.stage == .paused ? .secondary : .primary)
                            .contentTransition(.numericText())
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 10)
                .padding(.trailing, Self.controlsWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(CardButtonStyle())
            .accessibilityLabel([item.video.titleName, item.episodeLine, item.statusLine].compactMap(\.self).joined(separator: ", "))
            .accessibilityHint(isFinished ? "Plays it" : "Opens its page")
            .overlay(alignment: .trailing) {
                controls
                    .padding(.trailing, 14)
            }
        }
        .contextMenu {
            if isFinished, let file = item.fileURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            }
            Button("Open Its Page", action: open)
            Divider()
            Button(isFinished ? "Move to Trash" : "Remove Download", role: .destructive) {
                isConfirmingRemoval = true
            }
        }
        .confirmationDialog(
            isFinished ? "Move “\(item.video.title)” to the Trash?" : "Remove this download?",
            isPresented: $isConfirmingRemoval
        ) {
            Button(isFinished ? "Move to Trash" : "Remove", role: .destructive, action: remove)
        } message: {
            Text(isFinished
                ? "The file goes to the Trash; you can put it back from there."
                : "What has been downloaded of it so far is deleted.")
        }
    }

    /// Room kept at the row's trailing end for its buttons.
    private static let controlsWidth: CGFloat = 124

    private var artwork: some View {
        RemoteImage(url: item.video.poster, maxPointSize: 120, placeholderSystemImage: "film")
            .frame(width: 54, height: 80)
            .clipShape(.rect(cornerRadius: 7, style: .continuous))
            .overlay {
                if isFinished {
                    ZStack {
                        Color.black.opacity(0.35)
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                    .clipShape(.rect(cornerRadius: 7, style: .continuous))
                }
            }
            .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            switch item.stage {
            case .queued:
                Button(action: pause) {
                    Image(systemName: "pause.fill")
                }
                .accessibilityLabel("Pause Download")
                .help("Pause")
            case .paused:
                Button(action: resume) {
                    Image(systemName: "arrow.down")
                }
                .accessibilityLabel("Resume Download")
                .help("Resume")
            case .failed:
                Button(action: resume) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Try Again")
                .help("Try Again")
            case .finished:
                if let file = item.fileURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Show in Finder")
                    .help("Show in Finder")
                }
            }
            Button {
                isConfirmingRemoval = true
            } label: {
                Image(systemName: isFinished ? "trash" : "xmark")
            }
            .accessibilityLabel(isFinished ? "Move to Trash" : "Remove Download")
            .help(isFinished ? "Move to Trash" : "Remove")
        }
        .buttonStyle(IconButtonStyle())
    }
}
