import MediaCore
import SwiftUI

/// Owns the model for one pushed detail page and loads it.
struct DetailScreen: View {
    @State private var model: DetailModel
    private let registry: AddonRegistry
    private let streamPlayer: StreamPlayer
    private let library: LibraryCenter
    private let appIdentifier: String

    init(route: MediaRoute, appModel: AppModel) {
        _model = State(initialValue: appModel.detailModel(for: route))
        registry = appModel.registry
        streamPlayer = appModel.streamPlayer
        library = appModel.library
        appIdentifier = appModel.branding.bundleIdentifier
    }

    var body: some View {
        DetailView(model: model, appIdentifier: appIdentifier, playStream: { choice in
            guard let video = model.streamVideo else { return }
            model.streams.didChoose(choice)
            streamPlayer.play(choice, for: video)
        }, retry: {
            Task { await model.load(addons: registry.addons) }
        })
        .task(id: registry.addons.map(\.id)) {
            await model.load(addons: registry.addons)
        }
        // Watched marks and progress change while the page is up: the player saves as it goes.
        .task(id: library.revision) {
            await model.refreshLibraryState()
        }
    }
}

struct DetailView: View {
    @Bindable var model: DetailModel
    let appIdentifier: String
    var playStream: (StreamChoice) -> Void = { _ in }
    let retry: () -> Void

    @State private var trailer: YouTubeVideoID?

    private static let backdropHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 20) {
                    actions
                    if let description = model.meta?.description {
                        Text(description)
                            .font(.body)
                            .frame(maxWidth: 760, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    credits
                    status
                    if model.isSingleVideo {
                        StreamListView(model: model.streams, play: playStream)
                    }
                    videos
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
        .navigationTitle(model.title)
        .sheet(item: $trailer) { video in
            TrailerView(video: video, title: model.title, appIdentifier: appIdentifier)
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: model.meta?.background, maxPointSize: 1100, placeholderSystemImage: "photo")
                .frame(height: Self.backdropHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.75), location: 0.6),
                            .init(color: Color(nsColor: .windowBackgroundColor), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: 22) {
                RemoteImage(url: model.meta?.poster, maxPointSize: 240, placeholderSystemImage: "film")
                    .frame(width: 160, height: 240)
                    .clipShape(.rect(cornerRadius: 10))
                    .shadow(radius: 12, y: 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title)
                        .font(.largeTitle.bold())
                        .lineLimit(2)
                    if let facts = model.meta?.factLine, !facts.isEmpty {
                        Text(facts.joined(separator: "  ·  "))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    if let genres = model.meta?.genres, !genres.isEmpty {
                        Text(genres.joined(separator: ", "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Body sections

    private var actions: some View {
        HStack(spacing: 10) {
            if let video = model.trailer.flatMap({ YouTubeVideoID($0.youTubeID) }) {
                Button {
                    trailer = video
                } label: {
                    Label("Watch Trailer", systemImage: "play.rectangle")
                }
            }
            Button {
                Task { await model.toggleLibrary() }
            } label: {
                Label(model.isInLibrary ? "In Library" : "Add to Library", systemImage: model.isInLibrary ? "checkmark" : "plus")
            }
            .accessibilityHint(model.isInLibrary ? "Removes this title from your library" : "Saves this title to your library")
            .disabled(model.meta == nil)
            if model.isSingleVideo {
                Button {
                    Task { await model.setWatched(!model.isTitleWatched) }
                } label: {
                    Label(model.isTitleWatched ? "Watched" : "Mark as Watched", systemImage: model.isTitleWatched ? "eye.fill" : "eye")
                }
                .accessibilityHint(model.isTitleWatched ? "Marks this as not watched" : "Marks this as watched")
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var credits: some View {
        if let meta = model.meta {
            let rows: [(String, [String])] = [
                ("Cast", meta.cast),
                (meta.directors.count == 1 ? "Director" : "Directors", meta.directors),
                (meta.writers.count == 1 ? "Writer" : "Writers", meta.writers),
            ].filter { !$0.1.isEmpty }

            if !rows.isEmpty || meta.awards != nil {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(rows, id: \.0) { label, names in
                        GridRow {
                            Text(label).foregroundStyle(.secondary)
                            Text(names.joined(separator: ", "))
                        }
                    }
                    if let awards = meta.awards {
                        GridRow {
                            Text("Awards").foregroundStyle(.secondary)
                            Text(awards)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case let .failed(message):
            RetryMessage(message: message, retry: retry)
        case .loaded:
            EmptyView()
        }
    }

    @ViewBuilder private var videos: some View {
        if !model.seasons.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Season", selection: $model.selectedSeason) {
                        ForEach(model.seasons, id: \.self) { season in
                            Text(DetailModel.seasonTitle(season)).tag(Optional(season))
                        }
                    }
                    .fixedSize()
                    Button(model.isSeasonWatched ? "Mark Season as Not Watched" : "Mark Season as Watched") {
                        Task { await model.setSeasonWatched(!model.isSeasonWatched) }
                    }
                }

                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.episodes) { episode in
                        episodeRow(episode)
                    }
                }
            }
        } else if !model.looseVideos.isEmpty {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.looseVideos) { video in
                    episodeRow(video)
                }
            }
        }
    }

    /// An episode; clicking it shows its streams underneath.
    @ViewBuilder
    private func episodeRow(_ video: MetaVideo) -> some View {
        let isSelected = model.selectedVideoID == video.id
        let isWatched = model.isWatched(video)
        Button {
            model.toggleStreams(for: video)
        } label: {
            EpisodeRow(video: video, isWatched: isWatched, progress: model.progress(of: video))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(isWatched ? "Mark as Not Watched" : "Mark as Watched") {
                Task { await model.setWatched(!isWatched, video: video) }
            }
        }
        .accessibilityHint(isSelected ? "Hides this episode's streams" : "Shows this episode's streams")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        if isSelected {
            StreamListView(model: model.streams, play: playStream)
                .padding(.leading, 190)
                .padding(.bottom, 8)
        }
    }
}

private struct EpisodeRow: View {
    let video: MetaVideo
    var isWatched = false
    /// How far through it is, if it was started and not finished.
    var progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: video.thumbnail, maxPointSize: 176, placeholderSystemImage: "play.tv")
                .frame(width: 176, height: 99)
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressBar(fraction: progress)
                    }
                }
                .clipShape(.rect(cornerRadius: 6))
                .opacity(isWatched ? 0.55 : 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(video.numberedTitle)
                        .font(.headline)
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Watched")
                    }
                }
                if let released = video.released {
                    Text(DetailModel.releaseText(for: released))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let overview = video.overview {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A thin bar along the bottom of a picture showing how much of it has been watched.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.5))
                Rectangle().fill(.tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Watched")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
