import MediaCore
import SwiftUI

/// Discover: pick a type, a catalog and its filters, then scroll.
struct DiscoverView: View {
    let model: DiscoverModel
    let registry: AddonRegistry

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 18, alignment: .top)]

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
            VStack(spacing: 0) {
                filterBar
                Divider()
                results
            }
        }
    }

    private var filterBar: some View {
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

    @ViewBuilder private var results: some View {
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
        ScrollView {
            LazyVGrid(columns: columns, spacing: 22) {
                ForEach(model.items) { item in
                    PosterCard(item: item, sizing: .flexibleWidth)
                        .onAppear { model.itemDidAppear(item) }
                }
            }
            .padding(24)

            if model.phase == .loadingMore {
                ProgressView()
                    .padding(.bottom, 24)
            } else if case let .failed(message) = model.phase {
                RetryMessage(message: message) { model.retry() }
                    .padding(.bottom, 24)
            }
        }
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
