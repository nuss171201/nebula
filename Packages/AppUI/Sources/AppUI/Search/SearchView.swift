import SwiftUI

/// Search results, grouped by the add-on that found them.
struct SearchView: View {
    let model: SearchModel

    var body: some View {
        if !model.hasSearchableAddons {
            ContentUnavailableView(
                "Search Unavailable",
                systemImage: "magnifyingglass",
                description: Text("None of your enabled add-ons supports search.")
            )
        } else if model.sections.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(model.sections) { section in
                        SearchSectionView(section: section)
                    }
                    footer
                }
                .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.phase {
        case .idle, .searching:
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .finished:
            if model.failedAddonNames.isEmpty {
                ContentUnavailableView.search(text: model.trimmedQuery)
            } else {
                ContentUnavailableView(
                    "Search Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text("No results could be loaded from \(failedNames).")
                )
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if model.phase == .searching {
            ProgressView()
                .controlSize(.small)
                .padding(.horizontal, 24)
        } else if !model.failedAddonNames.isEmpty {
            Label("Search failed for \(failedNames).", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
    }

    private var failedNames: String {
        model.failedAddonNames.formatted(.list(type: .and))
    }
}

private struct SearchSectionView: View {
    let section: SearchSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.addonName)
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 24)
                .accessibilityAddTraits(.isHeader)

            ForEach(section.rows) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                    PosterStrip(items: row.items)
                }
            }
        }
    }
}
