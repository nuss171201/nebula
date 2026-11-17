import MediaCore
import SwiftUI

/// Discover: pick a type, a catalog and its filters, then scroll.
struct DiscoverView: View {
    let model: DiscoverModel
    let registry: AddonRegistry
    /// Opens a title's page.
    let open: (MetaItem) -> Void

    var body: some View {
        if !registry.isReady {
            ProgressView("Loading add-ons…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasCatalogs {
            ContentUnavailableView(
                "Nothing to Browse",
                systemImage: "safari",
                description: Text("Install or enable an add-on that provides catalogs, in Add-ons.")
            )
        } else {
            // Two views, so that each is evaluated again only for what it reads: a page arriving
            // changes the results and must not rebuild the pickers above them (it did, at 9 to
            // 10 ms a time in the middle of a scroll).
            VStack(spacing: 0) {
                DiscoverFilterBar(model: model)
                Divider()
                DiscoverResults(model: model, open: open)
            }
        }
    }
}

/// The pickers above the results: type, catalog and the catalog's filters.
private struct DiscoverFilterBar: View {
    let model: DiscoverModel

    var body: some View {
        HStack(spacing: 14) {
            Picker("Type", selection: typeBinding) {
                ForEach(model.types, id: \.self) { type in
                    Text(type.pluralTitle).tag(Optional(type))
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()

            Picker("Catalog", selection: catalogBinding) {
                ForEach(model.catalogs) { source in
                    Text(catalogTitle(source)).tag(Optional(source.id))
                }
            }
            .fixedSize()

            ForEach(model.filters) { filter in
                Picker(filter.title, selection: filterBinding(filter)) {
                    if !filter.isRequired {
                        Text("All").tag(String?.none)
                    }
                    ForEach(filter.options, id: \.self) { option in
                        Text(option).tag(Optional(option))
                    }
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    /// Catalog names repeat across add-ons ("Popular"), so name the add-on when there are several.
    private func catalogTitle(_ source: CatalogSource) -> String {
        let addonCount = Set(model.catalogs.map(\.addon.id)).count
        return addonCount > 1
            ? "\(source.catalog.displayName) — \(source.addon.manifest.name)"
            : source.catalog.displayName
    }

    private var typeBinding: Binding<MediaType?> {
        Binding {
            model.selectedType
        } set: { type in
            if let type {
                model.select(type: type)
            }
        }
    }

    private var catalogBinding: Binding<String?> {
        Binding {
            model.selectedCatalog?.id
        } set: { id in
            if let id {
                model.select(catalogID: id)
            }
        }
    }

    private func filterBinding(_ filter: DiscoverFilter) -> Binding<String?> {
        Binding {
            filter.selection
        } set: { option in
            model.setFilter(filter.name, to: option)
        }
    }
}

/// The catalog's titles, or what stands in for them while loading or when there are none.
private struct DiscoverResults: View {
    let model: DiscoverModel
    let open: (MetaItem) -> Void

    var body: some View {
        switch model.phase {
        case .idle, .loadingFirstPage:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message) where model.items.isEmpty:
            ContentUnavailableView {
                Label("Could Not Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
            }
        case .loaded where model.items.isEmpty:
            ContentUnavailableView(
                "No Results",
                systemImage: "film.stack",
                description: Text("This catalog has nothing for the selected filters.")
            )
        default:
            grid
        }
    }

    private var grid: some View {
        PosterGrid(
            items: model.items,
            footer: footer,
            itemDidAppear: { model.itemDidAppear($0) },
            open: open,
            retry: { model.retry() }
        )
    }

    private var footer: PosterGrid.Footer {
        switch model.phase {
        case .loadingMore: .loading
        case let .failed(message): .failed(message)
        default: .none
        }
    }
}
