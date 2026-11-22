import MediaCore
import MediaLibrary
import SwiftUI

/// What a board says when it has no catalogs to show.
struct BoardEmptyState: Equatable {
    var title: String
    var systemImage: String
    var message: String

    static let home = BoardEmptyState(
        title: "No Catalogs",
        systemImage: "house",
        message: "Install or enable an add-on that provides catalogs, in Add-ons."
    )
    static let anime = BoardEmptyState(
        title: "No Anime Catalogs",
        systemImage: "sparkles.tv",
        message: "Install or enable an add-on that provides anime catalogs, in Add-ons."
    )
}

/// A board of catalogs: what to carry on with, then one row per catalog. Home is one; the
/// Anime section is another, of the anime catalogs alone.
struct HomeView: View {
    let model: HomeModel
    let registry: AddonRegistry
    let continueWatching: ContinueWatchingModel
    let library: LibraryCenter
    /// Off when the user has hidden the row in Settings.
    var showsContinueWatching = true
    /// Off when the user has hidden the banner in Settings.
    var showsFeatured = true
    var emptyText = BoardEmptyState.home
    /// Opens a title's page and plays it.
    var play: (MetaItem) -> Void = { _ in }
    /// Opens a video's page with its streams showing.
    let open: (WatchVideo) -> Void

    /// The banner has titles, or may yet get some: its place is kept so the page does not jump.
    private var showsBanner: Bool {
        showsFeatured && (!model.featured.items.isEmpty || model.isFeaturedPending)
    }

    var body: some View {
        Group {
            if !registry.isReady {
                ProgressView("Loading add-ons…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rows.isEmpty, continueWatching.items.isEmpty || !showsContinueWatching {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        if showsBanner {
                            FeaturedBanner(model: model.featured, library: library, play: play)
                        }
                        if showsContinueWatching {
                            ContinueWatchingRow(model: continueWatching, open: open)
                        }
                        ForEach(model.rows) { row in
                            CatalogRowView(row: row)
                        }
                    }
                    .padding(.top, showsBanner ? 0 : 20)
                    .padding(.bottom, 20)
                }
            }
        }
        // The banner draws on the first rows, which may not have scrolled into view.
        .task(id: showsFeatured ? model.rows.prefix(HomeModel.featuredRowCount).map(\.id) : []) {
            if showsFeatured {
                await model.loadFeaturedRows()
            }
        }
        // What was watched changes while the app is open; so do the add-ons that can say what comes next.
        .task(id: "\(library.revision)|\(registry.addons.count)|\(showsContinueWatching)") {
            guard showsContinueWatching else { return }
            await continueWatching.reload()
        }
    }

    @ViewBuilder private var emptyState: some View {
        if let setupError = registry.setupError {
            ContentUnavailableView {
                Label("Could Not Load Catalogs", systemImage: "wifi.exclamationmark")
            } description: {
                Text(setupError)
            } actions: {
                Button("Try Again") {
                    Task { await registry.retrySetup() }
                }
            }
        } else {
            ContentUnavailableView(
                emptyText.title,
                systemImage: emptyText.systemImage,
                description: Text(emptyText.message)
            )
        }
    }
}

private struct CatalogRowView: View {
    let row: CatalogRowModel

    var body: some View {
        if !row.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // A mark in the accent's colours, so that the eye finds where each row starts.
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: 4, height: 17)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                        .accessibilityHidden(true)
                    Text(row.title)
                        .font(.title2.weight(.bold))
                    Text(row.addonName)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                content
            }
            .task {
                await row.loadIfNeeded()
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch row.state {
        case .idle, .loading:
            PlaceholderStrip()
        case let .loaded(items):
            PosterStrip(items: items)
        case let .failed(message):
            RetryMessage(message: message) {
                Task { await row.retry() }
            }
            .padding(.horizontal, 24)
            .frame(height: PosterCard.rowHeight, alignment: .topLeading)
        }
    }
}

/// Grey boxes the size of posters, shown while a row loads so the page does not jump.
private struct PlaceholderStrip: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(0 ..< 10, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.artworkRadius, style: .continuous)
                    .fill(Theme.cardFill())
                    .frame(width: PosterCard.rowArtworkHeight * 2 / 3, height: PosterCard.rowArtworkHeight)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: PosterCard.rowHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
    }
}
