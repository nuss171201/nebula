import Foundation
import MediaCore
import Observation

/// A catalog parameter the user picks from a list: genre, year and so on.
public struct DiscoverFilter: Identifiable, Hashable, Sendable {
    /// The parameter name sent to the add-on.
    public var name: String
    public var title: String
    public var options: [String]
    /// A required filter always has a selection; an optional one may be `nil` ("All").
    public var isRequired: Bool
    public var selection: String?

    public var id: String { name }

    init(property: ExtraProperty) {
        name = property.name
        options = property.options
        isRequired = property.isRequired
        selection = property.isRequired ? property.options.first : nil
        // Some add-ons publish a "by year" catalog whose genre options are years.
        let looksLikeYears = !options.isEmpty && options.allSatisfy { $0.count == 4 && Int($0) != nil }
        title = looksLikeYears ? "Year" : name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Discover: browse one catalog at a time, filtered by type and the catalog's own
/// parameters, loading further pages as the user scrolls.
@MainActor
@Observable
public final class DiscoverModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case loadingFirstPage
        case loaded
        case loadingMore
        case failed(String)
    }

    /// How close to the end (in items) the user must scroll before the next page is requested.
    static let pagingThreshold = 12

    public private(set) var types: [MediaType] = []
    public private(set) var selectedType: MediaType?
    /// Browsable catalogs of the selected type, across all add-ons.
    public private(set) var catalogs: [CatalogSource] = []
    public private(set) var selectedCatalog: CatalogSource?
    public private(set) var filters: [DiscoverFilter] = []
    public private(set) var items: [MetaItem] = []
    public private(set) var phase: Phase = .idle
    public private(set) var canLoadMore = false
    /// Whether any installed add-on offers something to browse.
    public private(set) var hasCatalogs = false

    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private var sources: [CatalogSource] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(client: AddonClient) {
        self.client = client
    }

    // MARK: - Intents

    public func update(addons: [InstalledAddon]) {
        let browsable = addons.catalogSources.filter(\.catalog.isBrowsable)
        guard browsable != sources else { return }
        sources = browsable
        hasCatalogs = !browsable.isEmpty
        types = Array(Set(browsable.map(\.catalog.type))).sorted(by: MediaType.displayOrder)

        let type = selectedType.flatMap { types.contains($0) ? $0 : nil } ?? types.first
        applySelection(type: type, catalogID: selectedCatalog?.id, keepFilters: true)
    }

    public func select(type: MediaType) {
        guard type != selectedType, types.contains(type) else { return }
        applySelection(type: type, catalogID: nil, keepFilters: false)
    }

    public func select(catalogID: String) {
        guard catalogID != selectedCatalog?.id else { return }
        applySelection(type: selectedType, catalogID: catalogID, keepFilters: false)
    }

    /// Sets a filter. Passing `nil` clears an optional filter; required filters ignore it.
    public func setFilter(_ name: String, to option: String?) {
        guard let index = filters.firstIndex(where: { $0.name == name }) else { return }
        let filter = filters[index]
        if let option {
            guard filter.options.contains(option) else { return }
        } else if filter.isRequired {
            return
        }
        guard filter.selection != option else { return }
        filters[index].selection = option
        reload()
    }

    /// Call as items appear on screen; requests the next page when the user nears the end.
    public func itemDidAppear(_ item: MetaItem) {
        guard canLoadMore, phase == .loaded,
              let index = items.lastIndex(where: { $0.id == item.id }),
              index >= items.count - Self.pagingThreshold
        else { return }
        loadPage(isFirst: false)
    }

    public func retry() {
        guard case .failed = phase else { return }
        loadPage(isFirst: items.isEmpty)
    }

    /// Waits for the request in flight, if any. For tests.
    func waitForLoading() async {
        await loadTask?.value
    }

    // MARK: - Loading

    private func applySelection(type: MediaType?, catalogID: String?, keepFilters: Bool) {
        selectedType = type
        catalogs = sources.filter { $0.catalog.type == type }
        let catalog = catalogs.first { $0.id == catalogID } ?? catalogs.first
        let previousFilters = filters
        let sameCatalog = catalog == selectedCatalog
        selectedCatalog = catalog
        filters = catalog?.catalog.selectableExtras.map(DiscoverFilter.init(property:)) ?? []
        if keepFilters, sameCatalog {
            filters = previousFilters
            if phase != .idle {
                return
            }
        }
        reload()
    }

    private func reload() {
        items = []
        canLoadMore = false
        loadPage(isFirst: true)
    }

    private func loadPage(isFirst: Bool) {
        loadTask?.cancel()
        generation += 1
        guard let catalog = selectedCatalog else {
            phase = .idle
            return
        }
        let current = generation
        let request = CatalogRequest(
            type: catalog.catalog.type,
            catalogID: catalog.catalog.id,
            extra: filters.compactMap { filter in filter.selection.map { .init(filter.name, $0) } },
            skip: isFirst ? 0 : items.count
        )
        phase = isFirst ? .loadingFirstPage : .loadingMore

        loadTask = Task { [client] in
            let result: Result<CatalogPage, AddonError>
            do throws(AddonError) {
                result = try await .success(client.catalog(request, from: catalog.addon.address))
            } catch {
                result = .failure(error)
            }
            // A newer selection superseded this request while it was in flight.
            guard current == generation else { return }
            apply(result, isFirst: isFirst, supportsPaging: catalog.catalog.supportsPaging)
        }
    }

    private func apply(_ result: Result<CatalogPage, AddonError>, isFirst: Bool, supportsPaging: Bool) {
        switch result {
        case let .success(page):
            let known = Set(items.map(\.id))
            var seen = known
            let fresh = page.items.filter { seen.insert($0.id).inserted }
            items.append(contentsOf: fresh)
            canLoadMore = supportsPaging && !fresh.isEmpty && (page.hasMore ?? true)
            phase = .loaded
        case let .failure(error):
            phase = error.isCancellation ? (isFirst ? .idle : .loaded) : .failed(error.userMessage)
        }
    }
}
