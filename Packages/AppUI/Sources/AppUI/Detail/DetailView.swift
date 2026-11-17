import MediaCore
import SwiftUI

/// Owns the model for one pushed detail page and loads it.
struct DetailScreen: View {
    @State private var model: DetailModel
    private let registry: AddonRegistry
    private let appIdentifier: String

    init(route: MediaRoute, appModel: AppModel) {
        _model = State(initialValue: appModel.detailModel(for: route))
        registry = appModel.registry
        appIdentifier = appModel.branding.bundleIdentifier
    }

    var body: some View {
        DetailView(model: model, appIdentifier: appIdentifier) {
            Task { await model.load(addons: registry.addons) }
        }
        .task(id: registry.addons.map(\.id)) {
            await model.load(addons: registry.addons)
        }
    }
}

struct DetailView: View {
    @Bindable var model: DetailModel
    let appIdentifier: String
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

    @ViewBuilder private var actions: some View {
        if let video = model.trailer.flatMap({ YouTubeVideoID($0.youTubeID) }) {
            Button {
                trailer = video
            } label: {
                Label("Watch Trailer", systemImage: "play.rectangle")
            }
            .controlSize(.large)
        }
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
                Picker("Season", selection: $model.selectedSeason) {
                    ForEach(model.seasons, id: \.self) { season in
                        Text(DetailModel.seasonTitle(season)).tag(Optional(season))
                    }
                }
                .fixedSize()

                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.episodes) { episode in
                        EpisodeRow(video: episode)
                    }
                }
            }
        } else if !model.looseVideos.isEmpty {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.looseVideos) { video in
                    EpisodeRow(video: video)
                }
            }
        }
    }
}

private struct EpisodeRow: View {
    let video: MetaVideo

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: video.thumbnail, maxPointSize: 176, placeholderSystemImage: "play.tv")
                .frame(width: 176, height: 99)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(video.numberedTitle)
                    .font(.headline)
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
