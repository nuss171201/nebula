import MediaLibrary
import SwiftUI

/// The Home board: what to carry on with, then one row per catalog.
struct HomeView: View {
    let model: HomeModel
    let registry: AddonRegistry
    let continueWatching: ContinueWatchingModel
    let library: LibraryCenter
    /// Off when the user has hidden the row in Settings.
    var showsContinueWatching = true
    /// Opens a video's page with its streams showing.
    let open: (WatchVideo) -> Void

    var body: some View {
        Group {
            if !registry.isReady {
                ProgressView("Loading add-ons…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rows.isEmpty, continueWatching.items.isEmpty || !showsContinueWatching {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if showsContinueWatching {
                            ContinueWatchingRow(model: continueWatching, open: open)
                        }
                        ForEach(model.rows) { row in
                            CatalogRowView(row: row)
                        }
                    }
                    .padding(.vertical, 20)
                }
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
                "No Catalogs",
                systemImage: "house",
                description: Text("Install or enable an add-on that provides catalogs, in Add-ons.")
            )
        }
    }
}

private struct CatalogRowView: View {
    let row: CatalogRowModel

    var body: some View {
        if !row.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title)
                        .font(.title3.weight(.semibold))
                    Text(row.addonName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
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
