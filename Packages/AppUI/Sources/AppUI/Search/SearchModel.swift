import Foundation
import MediaCore
import Observation

/// Results from one catalog of one add-on.
public struct SearchRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var items: [MetaItem]
}

/// Everything one add-on found, one row per catalog.
public struct SearchSection: Identifiable, Hashable, Sendable {
    public var id: String
    public var addonName: String
    public var rows: [SearchRow]
}

/// Searches every add-on that supports it. Typing is debounced; results appear per
/// add-on as each one answers, in a stable order.
@MainActor
@Observable
public final class SearchModel {
    public enum Phase: Equatable, Sendable {
        /// No query.
        case idle
        case searching
        case finished
    }

    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public var query = "" {
        didSet {
            if query != oldValue {
                queryDidChange()
            }
        }
    }

    public private(set) var sections: [SearchSection] = []
    public private(set) var phase: Phase = .idle
    /// Add-ons whose search failed for the current query.
    public private(set) var failedAddonNames: [String] = []
    /// Whether any installed add-on can be searched at all.
    public private(set) var hasSearchableAddons = false

    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var sources: [CatalogSource] = []
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(
        client: AddonClient,
        debounce: Duration = .milliseconds(300),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.debounce = debounce
        self.sleep = sleep
    }

    /// The query as it is sent: surrounding whitespace removed.
    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the search results should replace the current screen.
    public var isActive: Bool {
        !trimmedQuery.isEmpty
    }

    public func update(addons: [InstalledAddon]) {
        let searchable = addons.catalogSources.filter(\.catalog.isSearchable)
        guard searchable != sources else { return }
        sources = searchable
        hasSearchableAddons = !searchable.isEmpty
        if isActive {
            queryDidChange()
        }
    }

    /// Waits for the search in flight, if any. For tests.
    func waitForSearch() async {
        await searchTask?.value
    }

    private func queryDidChange() {
        searchTask?.cancel()
        generation += 1
        let current = generation
        let text = trimmedQuery

        guard !text.isEmpty else {
            sections = []
            failedAddonNames = []
            phase = .idle
            return
        }
        phase = .searching

        searchTask = Task { [debounce, sleep] in
            do {
                try await sleep(debounce)
            } catch {
                return
            }
            guard current == generation else { return }
            await search(for: text, generation: current)
        }
    }

    private func search(for text: String, generation current: Int) async {
        let sources = sources
        var results: [Int: [MetaItem]] = [:]
        var failed: [String] = []
        sections = []
        failedAddonNames = []

        await withTaskGroup(of: (Int, Result<[MetaItem], AddonError>).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { [client] in
                    let request = CatalogRequest(
                        type: source.catalog.type,
                        catalogID: source.catalog.id,
                        extra: [.init(ManifestCatalog.searchExtra, text)]
                    )
                    do throws(AddonError) {
                        return try await (index, .success(client.catalog(request, from: source.addon.address).items))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            for await (index, result) in group {
                guard current == generation else { continue }
                switch result {
                case let .success(items):
                    results[index] = items
                    sections = Self.sections(from: results, sources: sources)
                case let .failure(error) where !error.isCancellation:
                    let name = sources[index].addon.manifest.name
                    if !failed.contains(name) {
                        failed.append(name)
                        failedAddonNames = failed
                    }
                case .failure:
                    break
                }
            }
        }

        guard current == generation else { return }
        phase = .finished
    }

    /// Groups non-empty results by add-on, keeping add-on and catalog order.
    private static func sections(from results: [Int: [MetaItem]], sources: [CatalogSource]) -> [SearchSection] {
        var sections: [SearchSection] = []
        for (index, source) in sources.enumerated() {
            guard let items = results[index], !items.isEmpty else { continue }
            let row = SearchRow(id: source.id, title: source.catalog.type.pluralTitle, items: items)
            if let last = sections.indices.last, sections[last].id == source.addon.id {
                sections[last].rows.append(row)
            } else {
                sections.append(SearchSection(id: source.addon.id, addonName: source.addon.manifest.name, rows: [row]))
            }
        }
        return sections
    }
}
