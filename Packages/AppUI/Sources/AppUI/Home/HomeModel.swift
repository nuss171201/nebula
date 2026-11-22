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
    @ObservationIgnored private let didLoadItems: @MainActor () -> Void

    public init(source: CatalogSource, client: AddonClient, didLoadItems: @escaping @MainActor () -> Void = {}) {
        self.source = source
        self.client = client
        self.didLoadItems = didLoadItems
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
            if !page.items.isEmpty {
                didLoadItems()
            }
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
    /// The banner above the rows, filled from the first of them.
    public let featured = FeaturedModel()

    /// How many rows, from the top, the banner takes its titles from.
    static let featuredRowCount = 2

    /// Called once, the first time any row has items to show.
    @ObservationIgnored public var onFirstContent: (@MainActor () -> Void)?

    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private var hasShownContent = false
    @ObservationIgnored private let includes: @Sendable (CatalogSource) -> Bool

    /// - Parameter includes: Which catalogs belong on this board; all of them by default.
    public init(client: AddonClient, includes: @escaping @Sendable (CatalogSource) -> Bool = { _ in true }) {
        self.client = client
        self.includes = includes
    }

    /// Rebuilds the board for the given add-ons, keeping rows (and what they have
    /// loaded) whose catalog is unchanged.
    public func update(addons: [InstalledAddon]) {
        let existing = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        rows = addons.catalogSources
            .filter { $0.catalog.isBoardEligible && includes($0) && seen.insert($0.id).inserted }
            .map { source in
                if let row = existing[source.id], row.source == source {
                    return row
                }
                return CatalogRowModel(source: source, client: client) { [weak self] in
                    self?.rowDidLoadItems()
                }
            }
        refreshFeatured()
    }

    /// Whether the banner may still get titles: one of the rows it draws on has yet to answer.
    /// The page keeps the banner's place meanwhile, so that it does not jump when they arrive.
    public var isFeaturedPending: Bool {
        rows.prefix(Self.featuredRowCount).contains { row in
            switch row.state {
            case .idle, .loading: true
            case .loaded, .failed: false
            }
        }
    }

    /// Loads the rows the banner draws on, whether or not they have scrolled into view.
    public func loadFeaturedRows() async {
        await withTaskGroup(of: Void.self) { group in
            for row in rows.prefix(Self.featuredRowCount) {
                group.addTask { await row.loadIfNeeded() }
            }
        }
    }

    private func rowDidLoadItems() {
        refreshFeatured()
        guard !hasShownContent else { return }
        hasShownContent = true
        onFirstContent?()
    }

    private func refreshFeatured() {
        featured.update(FeaturedPicker.picks(from: rows.prefix(Self.featuredRowCount).compactMap(\.state.value)))
    }
}
