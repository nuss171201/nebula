import Foundation
import MediaCore
import Observation

/// One horizontally scrolling catalog on the Home board. Loads itself the first
/// time it scrolls into view.
@MainActor
@Observable
public final class CatalogRowModel: Identifiable {
    public let source: CatalogSource
    public private(set) var state: LoadState<[MetaItem]> = .idle

    @ObservationIgnored private let client: AddonClient

    public init(source: CatalogSource, client: AddonClient) {
        self.source = source
        self.client = client
    }

    public nonisolated var id: String {
        source.id
    }

    /// For example "Popular · Movies".
    public var title: String {
        "\(source.catalog.displayName) · \(source.catalog.type.pluralTitle)"
    }

    public var addonName: String {
        source.addon.manifest.name
    }

    /// A row that loaded successfully but has nothing in it is not worth showing.
    public var isEmpty: Bool {
        state.value?.isEmpty == true
    }

    public func loadIfNeeded() async {
        guard case .idle = state else { return }
        await load()
    }

    public func retry() async {
        guard !state.isLoading else { return }
        await load()
    }

    private func load() async {
        state = .loading
        do {
            let request = CatalogRequest(type: source.catalog.type, catalogID: source.catalog.id)
            let page = try await client.catalog(request, from: source.addon.address)
            state = .loaded(page.items)
        } catch {
            // Scrolled away mid-load: go back to idle so it loads when visible again.
            state = error.isCancellation ? .idle : .failed(error.userMessage)
        }
    }
}

/// The Home board: every catalog that can be shown without choosing a filter first.
@MainActor
@Observable
public final class HomeModel {
    public private(set) var rows: [CatalogRowModel] = []

    @ObservationIgnored private let client: AddonClient

    public init(client: AddonClient) {
        self.client = client
    }

    /// Rebuilds the board for the given add-ons, keeping rows (and what they have
    /// loaded) whose catalog is unchanged.
    public func update(addons: [InstalledAddon]) {
        let existing = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        rows = addons.catalogSources
            .filter { $0.catalog.isBoardEligible && seen.insert($0.id).inserted }
            .map { source in
                if let row = existing[source.id], row.source == source {
                    return row
                }
                return CatalogRowModel(source: source, client: client)
            }
    }
}
