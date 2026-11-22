import MediaCore
import MediaLibrary
import SwiftUI

/// The Library screen: titles the user saved, and the history of what was watched.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    let library: LibraryCenter
    /// Opens a video's page with its streams showing.
    let open: (WatchVideo) -> Void

    @State private var isConfirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            switch model.tab {
            case .saved: saved
            case .history: history
            }
        }
        // Reloads whenever anything in the library changes, wherever it was changed.
        .task(id: library.revision) {
            await model.reload()
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            PillPicker(
                options: LibraryModel.Tab.allCases,
                selection: model.tab,
                title: \.title,
                select: { model.tab = $0 }
            )
            .fixedSize()
            Spacer()
            if model.tab == .saved {
                if model.availableTypes.count > 1 {
                    Picker("Type", selection: $model.typeFilter) {
                        Text("All").tag(MediaType?.none)
                        ForEach(model.availableTypes, id: \.self) { type in
                            Text(type.pluralTitle).tag(Optional(type))
                        }
                    }
                    .fixedSize()
                }
                Picker("Sort by", selection: $model.order) {
                    Text("Recently Added").tag(LibraryStore.Order.recentlyAdded)
                    Text("Name").tag(LibraryStore.Order.name)
                }
                .fixedSize()
            } else if !model.history.isEmpty {
                Button("Clear History…") {
                    isConfirmingClear = true
                }
                .confirmationDialog("Clear the whole watch history?", isPresented: $isConfirmingClear) {
                    Button("Clear History", role: .destructive) {
                        Task { await model.clearHistory() }
                    }
                } message: {
                    Text("Watched marks and where you left each video will be forgotten. Saved titles are kept.")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var saved: some View {
        if model.items.isEmpty, model.hasLoaded {
            ContentUnavailableView(
                "No Saved Titles",
                systemImage: "books.vertical",
                description: Text("Use Add to Library on a film's or series' page to keep it here.")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18)], alignment: .leading, spacing: 22) {
                    ForEach(model.items) { item in
                        PosterCard(item: item.metaItem, sizing: .flexibleWidth)
                            .contextMenu {
                                Button("Remove from Library") {
                                    Task { await model.remove(item) }
                                }
                            }
                    }
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder private var history: some View {
        if model.history.isEmpty, model.hasLoaded {
            ContentUnavailableView(
                "Nothing Watched Yet",
                systemImage: "clock",
                description: Text("What you watch from a film's or series' page is listed here.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.history) { entry in
                        HistoryRow(entry: entry) {
                            open(entry.video)
                        }
                    }
                }
                .padding(24)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: WatchEntry
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                RemoteImage(url: entry.video.poster, maxPointSize: 90, placeholderSystemImage: "film")
                    .frame(width: 46, height: 68)
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.video.titleName)
                        .font(.headline)
                        .lineLimit(1)
                    if let line = ContinueItem(video: entry.video, kind: .resume).episodeLine {
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .buttonStyle(CardButtonStyle())
        .frame(maxWidth: 760, alignment: .leading)
        .accessibilityHint("Opens its page")
    }

    private var status: String {
        let when = entry.lastWatchedAt.formatted(date: .abbreviated, time: .shortened)
        if entry.isWatched {
            return "Watched · \(when)"
        }
        if let progress = entry.progress {
            return "\(Int((progress * 100).rounded())) % watched · \(when)"
        }
        return when
    }
}

/// The Continue Watching row at the top of Home.
struct ContinueWatchingRow: View {
    let model: ContinueWatchingModel
    let open: (WatchVideo) -> Void

    static let artworkHeight: CGFloat = 150

    var body: some View {
        if !model.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: 4, height: 17)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                        .accessibilityHidden(true)
                    Text("Continue Watching")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.horizontal, 24)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(model.items) { item in
                            ContinueCard(item: item) {
                                open(item.video)
                            }
                            .contextMenu {
                                Button("Remove from Continue Watching") {
                                    Task { await model.dismiss(item) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }
}

private struct ContinueCard: View {
    let item: ContinueItem
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: item.video.poster, maxPointSize: 200, placeholderSystemImage: "film")
                    .frame(width: ContinueWatchingRow.artworkHeight * 2 / 3, height: ContinueWatchingRow.artworkHeight)
                    .overlay(alignment: .bottom) {
                        if let progress = item.progress {
                            ProgressBar(fraction: progress)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.video.titleName)
                        .font(.headline)
                        .lineLimit(2)
                    if let line = item.episodeLine {
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Label(item.statusLine, systemImage: item.kind == .resume ? "play.fill" : "forward.end.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
                .frame(width: 170, height: ContinueWatchingRow.artworkHeight, alignment: .topLeading)
            }
            .padding(8)
        }
        .buttonStyle(CardButtonStyle())
        .accessibilityLabel([item.video.titleName, item.episodeLine, item.statusLine].compactMap(\.self).joined(separator: ", "))
        .accessibilityHint("Opens its page with its streams")
    }
}
