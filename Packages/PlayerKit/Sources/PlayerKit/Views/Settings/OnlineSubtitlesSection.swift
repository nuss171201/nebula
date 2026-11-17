import MediaCore
import SwiftUI

/// "Find Subtitles Online" in the subtitle tab: name the title, pick it, pick a subtitle.
struct OnlineSubtitlesSection: View {
    @Bindable var model: OnlineSubtitlesModel
    let player: PlayerModel

    var body: some View {
        SettingsSection(title: "Find Subtitles Online") {
            if let title = model.chosenTitle {
                chosen(title)
            } else {
                titleSearch
            }
        }
        .disabled(!player.state.hasMedia)
        .onChange(of: player.source, initial: true) { _, source in
            model.prepare(for: source)
        }
    }

    // MARK: - Step 1: which title is this?

    @ViewBuilder private var titleSearch: some View {
        HStack {
            TextField("Film or series name", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.searchTitles)
                .accessibilityLabel("Film or series name")
            Button("Search", action: model.searchTitles)
                .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        switch model.titlePhase {
        case .idle:
            Text("Say what this video is, and subtitles for it are looked up in your subtitle add-ons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .searching:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Searching")
        case let .results(titles) where titles.isEmpty:
            Text("Nothing found under that name.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case let .results(titles):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(titles.prefix(8)) { title in
                    Button {
                        model.choose(title)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title.name)
                                .font(.callout)
                                .lineLimit(2)
                            Text([title.kindName, title.year].compactMap(\.self).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        case let .failed(message):
            FailureNote(message: message, retry: model.searchTitles)
        }
    }

    // MARK: - Step 2: which subtitle?

    @ViewBuilder
    private func chosen(_ title: SubtitleTitleMatch) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if let year = title.year {
                    Text(year)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Change", action: model.clearTitle)
                .buttonStyle(.borderless)
        }
        if title.type == .series {
            HStack {
                Stepper("Season \(model.season)", value: $model.season, in: 0 ... 99)
                Stepper("Episode \(model.episode)", value: $model.episode, in: 0 ... 999)
            }
            .font(.callout)
        }
        if let error = model.downloadError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
        switch model.subtitlePhase {
        case .idle:
            EmptyView()
        case .searching:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Looking for subtitles")
        case let .results(groups) where groups.isEmpty:
            Text("No subtitles were found for this title.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case let .results(groups):
            ForEach(groups) { group in
                DisclosureGroup("\(group.name) (\(group.subtitles.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(group.subtitles.prefix(25).enumerated()), id: \.element.id) { index, subtitle in
                            row(subtitle, number: index + 1, languageName: group.name)
                        }
                    }
                }
                .font(.callout)
            }
        case let .failed(message):
            FailureNote(message: message, retry: model.findSubtitles)
        }
    }

    private func row(_ subtitle: OnlineSubtitle, number: Int, languageName: String) -> some View {
        Button {
            model.use(subtitle)
        } label: {
            HStack(spacing: 8) {
                Group {
                    if model.downloadingID == subtitle.id {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: model.addedIDs.contains(subtitle.id) ? "checkmark" : "arrow.down.circle")
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subtitle.releaseName ?? "\(languageName) \(number)")
                        .font(.caption)
                        .lineLimit(2)
                    Text(subtitle.providerName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.downloadingID != nil)
        .accessibilityLabel("\(languageName) subtitle \(number)" + (subtitle.releaseName.map { ", for \($0)" } ?? ""))
        .accessibilityHint(model.addedIDs.contains(subtitle.id) ? "Already added" : "Downloads and shows this subtitle")
    }
}

/// What went wrong, with a way to try again.
private struct FailureNote: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Try Again", action: retry)
        }
    }
}
