import MediaLibrary
import SwiftUI

/// The Calendar screen: recent and upcoming episodes of saved series, day by day.
struct CalendarView: View {
    let model: CalendarModel
    let library: LibraryCenter
    let registry: AddonRegistry
    /// Opens an episode's page with its streams showing.
    let open: (WatchVideo) -> Void

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading:
                ProgressView("Loading episodes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Could Not Load the Calendar", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") {
                        Task { await model.reload() }
                    }
                }
            case .loaded where !model.hasSeries:
                ContentUnavailableView(
                    "No Series in Your Library",
                    systemImage: "calendar",
                    description: Text("Add a series to your library to see when its episodes air.")
                )
            case .loaded where model.days.isEmpty:
                ContentUnavailableView(
                    "Nothing Coming Up",
                    systemImage: "calendar",
                    description: Text("None of your series has an episode in the last week or the next three months.")
                )
            case .loaded:
                list
            }
        }
        // The saved series change, and so do the add-ons that know their episodes.
        .task(id: "\(library.revision)|\(registry.addons.map(\.id).joined())") {
            await model.reload()
        }
    }

    private var list: some View {
        let now = Date()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.days) { day in
                        Section {
                            ForEach(day.episodes) { episode in
                                CalendarRow(episode: episode, hasAired: episode.date <= now) {
                                    open(episode.watchVideo)
                                }
                            }
                        } header: {
                            Text(CalendarBuilder.title(for: day.date, now: now))
                                .font(.headline)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .id(day.date)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .onAppear {
                // Start at today (or the next day with an episode), not a week back.
                let today = Calendar.current.startOfDay(for: now)
                if let first = model.days.first(where: { $0.date >= today }) {
                    proxy.scrollTo(first.date, anchor: .top)
                }
            }
        }
    }
}

private struct CalendarRow: View {
    let episode: CalendarEpisode
    let hasAired: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                RemoteImage(url: episode.poster, maxPointSize: 90, placeholderSystemImage: "tv")
                    .frame(width: 46, height: 68)
                    .clipShape(.rect(cornerRadius: 4))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.seriesName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(episode.episodeLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(hasAired ? "Aired \(time)" : "Airs \(time)")
                        .font(.caption)
                        .foregroundStyle(hasAired ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: 760, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the episode's page")
    }

    private var time: String {
        episode.date.formatted(date: .omitted, time: .shortened)
    }
}
