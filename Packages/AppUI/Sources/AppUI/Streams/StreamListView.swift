import MediaCore
import SwiftUI

/// The streams for one video: a Play button that chooses for the user, with the whole list
/// a click away; or the whole list, for those who would rather choose (Settings → Streaming).
struct StreamListView: View {
    @Bindable var model: StreamListModel
    let play: (StreamChoice) -> Void
    /// Plays what the picker thinks best.
    var playBest: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.presentation == .playButton {
                playButton
                if model.showsAllStreams {
                    list
                }
            } else {
                list
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    // MARK: Play, chosen for the user

    @ViewBuilder private var playButton: some View {
        if !model.hasProviders {
            // Neutral on purpose: where streams come from is the user's choice.
            emptyNote("None of your add-ons offers streams for this. Streams come from add-ons you install on the Add-ons page.")
        } else if let best = model.picks.first {
            HStack(alignment: .center, spacing: 14) {
                Button(action: playBest) {
                    Label("Play", systemImage: "play.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Plays \(best.summary) from \(best.choice.addonName)")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(best.summary) · \(best.choice.addonName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let caution = Self.caution(for: best.standing) {
                        Label(caution, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.phase == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Looking for more streams")
                }
            }
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

    private var otherStreamsToggle: some View {
        Button {
            model.showsAllStreams.toggle()
        } label: {
            Label(
                model.showsAllStreams ? "Hide the List" : "All Streams (\(model.choices.count))",
                systemImage: model.showsAllStreams ? "chevron.up" : "chevron.down"
            )
            .font(.callout)
        }
        .buttonStyle(.link)
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
                .font(.title3.weight(.semibold))
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
                Text(model.suggestionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                StreamRow(choice: suggested, play: play)
            }
        }

        ForEach(model.groups) { group in
            VStack(alignment: .leading, spacing: 6) {
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(group.choices) { choice in
                    StreamRow(choice: choice, play: play)
                }
            }
        }

        if !model.failedAddonNames.isEmpty, !model.choices.isEmpty {
            Text("Did not answer: \(model.failedAddonNames.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
    let play: (StreamChoice) -> Void

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
                        .font(.callout.weight(.medium))
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
                if let quality = choice.quality {
                    Text(quality.label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel([choice.title, choice.quality?.label, choice.sizeText, choice.kindLabel, "from \(choice.addonName)"]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityHint("Plays this stream")
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

    private func bar(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12, content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
    }
}
