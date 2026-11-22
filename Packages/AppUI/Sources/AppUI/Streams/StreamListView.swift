import AppKit
import MediaCore
import SwiftUI

/// The streams for one video: a Play button that chooses for the user, with the whole list
/// a click away; or the whole list, for those who would rather choose (Settings → Streaming).
/// Beside Play, a button that keeps the same stream for watching without a connection.
struct StreamListView: View {
    @Bindable var model: StreamListModel
    /// The video the streams are of, for its download.
    var video: StreamVideo?
    var downloads: DownloadCenter?
    let play: (StreamChoice) -> Void
    /// Plays what the picker thinks best (the downloaded file, if there is one).
    var playBest: () -> Void = {}

    /// The video's download, if it has one.
    private var download: DownloadItem? {
        video.flatMap { downloads?.item(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.presentation == .playButton {
                playButton
                if model.showsAllStreams {
                    list
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            } else {
                list
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
        .animation(.snappy(duration: 0.3), value: model.showsAllStreams)
        .animation(.snappy(duration: 0.3), value: model.picks.first?.id)
    }

    // MARK: Play, chosen for the user

    @ViewBuilder private var playButton: some View {
        if download?.stage == .finished {
            // Plays from this Mac, whatever the add-ons say (or do not, without a connection).
            playRow(caption: ["Downloaded", download?.summary].compactMap(\.self).joined(separator: " · "), caution: nil, best: model.picks.first)
            if !model.choices.isEmpty {
                otherStreamsToggle
            }
        } else if !model.hasProviders {
            // Neutral on purpose: where streams come from is the user's choice.
            emptyNote("None of your add-ons offers streams for this. Streams come from add-ons you install on the Add-ons page.")
        } else if let best = model.picks.first {
            playRow(caption: "\(best.summary) · \(best.choice.addonName)", caution: Self.caution(for: best.standing), best: best)
            otherStreamsToggle
        } else if model.phase == .finished {
            if model.choices.isEmpty {
                emptyNote(model.failedAddonNames.isEmpty
                    ? "Your add-ons have no streams for this."
                    : "No streams were found, and some add-ons did not answer.")
            } else {
                emptyNote("Nothing here can be played with one click. Choose from what there is:")
                list
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for streams…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func playRow(caption: String, caution: String?, best: StreamPick?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: playBest) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(ProminentPillButtonStyle())
            .accessibilityHint(best.map { "Plays \($0.summary) from \($0.choice.addonName)" } ?? "Plays the downloaded file")
            if let video, let downloads {
                DownloadButton(
                    item: download,
                    // What Play would play, or the nearest thing to it that can be kept.
                    start: model.picks.map(\.choice).first(where: DownloadCenter.canDownload).map { choice in { _ = downloads.add(choice, for: video) } },
                    center: downloads
                )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let caution {
                    Label(caution, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)
            if model.phase == .loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Looking for more streams")
            }
        }
    }

    private var otherStreamsToggle: some View {
        Button {
            model.showsAllStreams.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(model.showsAllStreams ? "Hide the List" : "All Streams (\(model.choices.count))")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(model.showsAllStreams ? 180 : 0))
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows every stream, to choose one yourself")
    }

    /// What to say under Play when the best there is still has a drawback.
    nonisolated static func caution(for standing: StreamPick.Standing) -> String? {
        switch standing {
        case .good: nil
        case .fewPeers: "Few people are sharing this, so it may be slow to start."
        case .tooHeavy: "The smallest there is, and still more than this connection has been seen to manage: it may stop to load."
        case .overLimit: "Everything here is above the limits in Settings; this is the nearest."
        case .wrongLanguage: "Nothing here says it is in your languages."
        }
    }

    // MARK: The whole list

    @ViewBuilder private var list: some View {
        HStack {
            Text("Streams")
                .font(.title3.weight(.bold))
            if model.phase == .loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Looking for streams")
            }
            Spacer()
            if model.choices.count > 1 {
                Picker("Sort by", selection: $model.sort) {
                    ForEach(StreamSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .fixedSize()
            }
        }

        if model.presentation == .fullList {
            if !model.hasProviders {
                // Neutral on purpose: where streams come from is the user's choice.
                emptyNote("None of your add-ons offers streams for this. Streams come from add-ons you install on the Add-ons page.")
            } else if model.phase == .finished, model.choices.isEmpty {
                emptyNote(model.failedAddonNames.isEmpty
                    ? "Your add-ons have no streams for this."
                    : "No streams were found, and some add-ons did not answer.")
            }
        }

        if let suggested = model.suggested {
            VStack(alignment: .leading, spacing: 6) {
                groupTitle(model.suggestionTitle)
                row(suggested, isHighlighted: true)
            }
        }

        ForEach(model.groups) { group in
            VStack(alignment: .leading, spacing: 6) {
                groupTitle(group.title)
                ForEach(group.choices) { choice in
                    row(choice, isHighlighted: false)
                }
            }
        }

        if !model.failedAddonNames.isEmpty, !model.choices.isEmpty {
            Text("Did not answer: \(model.failedAddonNames.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ choice: StreamChoice, isHighlighted: Bool) -> some View {
        StreamRow(
            choice: choice,
            isHighlighted: isHighlighted,
            play: play,
            download: video.flatMap { video in
                downloads.flatMap { center in DownloadCenter.canDownload(choice) ? { _ = center.add(choice, for: video) } : nil }
            }
        )
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StreamRow: View {
    let choice: StreamChoice
    var isHighlighted = false
    let play: (StreamChoice) -> Void
    /// Keeps this stream's file; `nil` for the kinds that cannot be downloaded.
    var download: (() -> Void)?

    var body: some View {
        Button {
            play(choice)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    if let detail = choice.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    ForEach(StreamBadge.badges(for: choice), id: \.self) { badge in
                        StreamBadgeView(badge: badge)
                    }
                }
                // Room for the download button, which sits on the row and not in it.
                .padding(.trailing, download == nil ? 0 : 38)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(CardButtonStyle(isHighlighted: isHighlighted))
        .accessibilityLabel([choice.title, choice.quality?.label, choice.sizeText, choice.kindLabel, "from \(choice.addonName)"]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityHint("Plays this stream")
        .overlay(alignment: .topTrailing) {
            if let download {
                Button(action: download) {
                    Image(systemName: "arrow.down.to.line")
                }
                .buttonStyle(IconButtonStyle(diameter: 28))
                .padding(8)
                .accessibilityLabel("Download \(choice.title)")
                .help("Download: keeps this for watching without a connection")
            }
        }
    }

    private var symbol: String {
        switch choice.kind {
        case .torrent: "arrow.down.circle"
        case .direct: "play.circle"
        case .youTube: "play.rectangle"
        case .external: "safari"
        }
    }

    private var footnote: String {
        [choice.addonName, choice.kindLabel, choice.sizeText].compactMap(\.self).joined(separator: " · ")
    }
}

/// What is shown along the bottom of the window while a torrent is being found, and when it could not be.
struct StreamStatusBar: View {
    let player: StreamPlayer

    var body: some View {
        switch player.phase {
        case .idle:
            EmptyView()
        case let .preparing(title, detail):
            bar {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: player.cancel)
            }
        case let .failed(title, message):
            bar {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Dismiss", action: player.cancel)
            }
        }
    }

    /// A panel that floats above the bottom edge, so that it reads as news and not as chrome.
    private func bar(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12, content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.cardStroke(isHovered: true), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
    }
}
