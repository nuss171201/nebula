import MediaCore
import SwiftUI

/// Owns the model for one pushed detail page and loads it.
struct DetailScreen: View {
    @State private var model: DetailModel
    private let registry: AddonRegistry
    private let streamPlayer: StreamPlayer
    private let library: LibraryCenter
    private let downloads: DownloadCenter
    private let appIdentifier: String
    private let playBest: @MainActor (DetailModel) -> Void
    private let didAppear: @MainActor (DetailModel) -> Void
    private let playWhenReady: @MainActor (DetailModel) async -> Void

    init(route: MediaRoute, appModel: AppModel) {
        _model = State(initialValue: appModel.detailModel(for: route))
        playBest = { [appModel] in appModel.playBestStream(of: $0) }
        didAppear = { [appModel] in appModel.detailDidAppear($0) }
        playWhenReady = { [appModel] in await appModel.playWhenReady($0) }
        registry = appModel.registry
        streamPlayer = appModel.streamPlayer
        library = appModel.library
        downloads = appModel.downloads
        appIdentifier = appModel.branding.bundleIdentifier
    }

    var body: some View {
        DetailView(model: model, appIdentifier: appIdentifier, downloads: downloads, playStream: { choice in
            guard let video = model.streamVideo else { return }
            model.streams.didChoose(choice)
            streamPlayer.play(choice, for: video)
        }, playBest: {
            playBest(model)
        }, retry: {
            Task { await model.load(addons: registry.addons) }
        })
        .task(id: registry.addons.map(\.id)) {
            didAppear(model)
            await model.load(addons: registry.addons)
            // Opened by a Play button elsewhere: play as soon as there is something to play.
            await playWhenReady(model)
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
    var downloads: DownloadCenter?
    var playStream: (StreamChoice) -> Void = { _ in }
    /// Plays the stream the app thinks best.
    var playBest: () -> Void = {}
    let retry: () -> Void

    @State private var trailer: YouTubeVideoID?

    private static let backdropHeight: CGFloat = 400

    /// Play goes right under the title when it is one button; a whole list of streams goes
    /// below what the title is about.
    private var showsPlayFirst: Bool {
        model.isSingleVideo && model.streams.presentation == .playButton
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 22) {
                    if showsPlayFirst {
                        streams
                    }
                    actions
                    if let description = model.meta?.description {
                        Text(description)
                            .font(.body)
                            .lineSpacing(3)
                            .frame(maxWidth: 760, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    credits
                    status
                    if model.isSingleVideo, !showsPlayFirst {
                        streams
                    }
                    videos
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
        }
        // The backdrop runs up under the toolbar.
        .ignoresSafeArea(edges: .top)
        .navigationTitle(model.title)
        .sheet(item: $trailer) { video in
            TrailerView(video: video, title: model.title, appIdentifier: appIdentifier)
        }
    }

    private var streams: some View {
        StreamListView(model: model.streams, video: model.streamVideo, downloads: downloads, play: playStream, playBest: playBest)
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: model.meta?.background, maxPointSize: 1100, placeholderSystemImage: "photo")
                .frame(height: Self.backdropHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                // The picture thins out into the page instead of ending at a line.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.85), location: 0.35),
                            .init(color: .black.opacity(0.25), location: 0.8),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .accessibilityHidden(true)

            HStack(alignment: .bottom, spacing: 24) {
                RemoteImage(url: model.meta?.poster, maxPointSize: 260, placeholderSystemImage: "film")
                    .frame(width: 170, height: 255)
                    .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 10) {
                    Text(model.title)
                        .font(.system(size: 36, weight: .bold))
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                    if let meta = model.meta {
                        facts(of: meta)
                        if !meta.genres.isEmpty {
                            Text(meta.genres.prefix(5).joined(separator: "  ·  "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    /// Year, running time and rating, each in a capsule.
    @ViewBuilder
    private func facts(of meta: MetaItem) -> some View {
        let plain = [meta.releaseInfo, meta.runtime].compactMap(\.self)
        if !plain.isEmpty || meta.ratingText != nil {
            HStack(spacing: 8) {
                ForEach(plain, id: \.self) { fact in
                    Chip(text: fact)
                }
                if let rating = meta.ratingText {
                    Chip(text: rating, systemImage: "star.fill", tint: .yellow)
                        .accessibilityLabel("Rated \(rating) out of 10")
                }
            }
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
                .buttonStyle(PillButtonStyle())
            }
            Button {
                Task { await model.toggleLibrary() }
            } label: {
                Label(model.isInLibrary ? "In Library" : "Add to Library", systemImage: model.isInLibrary ? "checkmark" : "plus")
            }
            .buttonStyle(PillButtonStyle(isOn: model.isInLibrary))
            .accessibilityHint(model.isInLibrary ? "Removes this title from your library" : "Saves this title to your library")
            .disabled(model.meta == nil)
            if model.isSingleVideo {
                Button {
                    Task { await model.setWatched(!model.isTitleWatched) }
                } label: {
                    Label(model.isTitleWatched ? "Watched" : "Mark as Watched", systemImage: model.isTitleWatched ? "eye.fill" : "eye")
                }
                .buttonStyle(PillButtonStyle(isOn: model.isTitleWatched))
                .accessibilityHint(model.isTitleWatched ? "Marks this as not watched" : "Marks this as watched")
            }
        }
        .animation(Theme.hover, value: model.isInLibrary)
        .animation(Theme.hover, value: model.isTitleWatched)
    }

    @ViewBuilder private var credits: some View {
        if let meta = model.meta {
            let rows: [(String, [String])] = [
                ("Cast", meta.cast),
                (meta.directors.count == 1 ? "Director" : "Directors", meta.directors),
                (meta.writers.count == 1 ? "Writer" : "Writers", meta.writers),
            ].filter { !$0.1.isEmpty }

            if !rows.isEmpty || meta.awards != nil {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 7) {
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
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(maxWidth: 760, alignment: .leading)
                .background(Theme.cardFill(), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Theme.cardStroke(), lineWidth: 1)
                }
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    // A handful of seasons fit in a row of capsules; more than that take a menu.
                    if model.seasons.count <= 8 {
                        PillPicker(
                            options: model.seasons,
                            selection: model.selectedSeason,
                            title: { DetailModel.seasonTitle($0) },
                            select: { model.selectedSeason = $0 },
                            label: "Season"
                        )
                    } else {
                        Picker("Season", selection: $model.selectedSeason) {
                            ForEach(model.seasons, id: \.self) { season in
                                Text(DetailModel.seasonTitle(season)).tag(Optional(season))
                            }
                        }
                        .fixedSize()
                    }
                    Spacer(minLength: 8)
                    Button(model.isSeasonWatched ? "Mark Season as Not Watched" : "Mark Season as Watched") {
                        Task { await model.setSeasonWatched(!model.isSeasonWatched) }
                    }
                    .buttonStyle(PillButtonStyle(isOn: model.isSeasonWatched))
                }
                .frame(maxWidth: 900, alignment: .leading)

                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.episodes) { episode in
                        episodeRow(episode)
                    }
                }
            }
        } else if !model.looseVideos.isEmpty {
            LazyVStack(alignment: .leading, spacing: 10) {
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
            EpisodeRow(video: video, isWatched: isWatched, isSelected: isSelected, progress: model.progress(of: video))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(CardButtonStyle(isHighlighted: isSelected))
        .frame(maxWidth: 900, alignment: .leading)
        .contextMenu {
            Button(isWatched ? "Mark as Not Watched" : "Mark as Watched") {
                Task { await model.setWatched(!isWatched, video: video) }
            }
        }
        .accessibilityHint(isSelected ? "Hides this episode's streams" : "Shows this episode's streams")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        if isSelected {
            streams
                .padding(.leading, 198)
                .padding(.vertical, 6)
        }
    }
}

private struct EpisodeRow: View {
    let video: MetaVideo
    var isWatched = false
    var isSelected = false
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
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
                .opacity(isWatched ? 0.55 : 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(video.numberedTitle)
                        .font(.headline)
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
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
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isSelected ? 180 : 0))
                .padding(.top, 4)
                .padding(.trailing, 6)
                .accessibilityHidden(true)
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
                Rectangle().fill(Theme.accentGradient).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Watched")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
