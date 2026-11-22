import Foundation
import MediaCore
import MediaLibrary
import Observation

/// Chooses what the banner at the top of Home shows.
public enum FeaturedPicker {
    /// How many titles the banner turns through.
    public static let limit = 6

    /// The first few titles of each row in turn, so that with a row of films and a row of
    /// series the two alternate. Only titles with a backdrop (the banner is a picture first),
    /// each once. Nothing is ranked here: the rows are in the order the user's add-ons give.
    public static func picks(from rows: [[MetaItem]], limit: Int = FeaturedPicker.limit) -> [MetaItem] {
        let candidates = rows.map { row in row.filter { $0.background != nil && !$0.name.isEmpty } }
        var seen = Set<String>()
        var picks: [MetaItem] = []
        for position in 0 ..< (candidates.map(\.count).max() ?? 0) {
            for row in candidates where position < row.count {
                guard picks.count < limit else { return picks }
                if seen.insert(FeaturedModel.key(row[position])).inserted {
                    picks.append(row[position])
                }
            }
        }
        return picks
    }
}

/// The banner at the top of Home: a few titles, one showing at a time.
@MainActor
@Observable
public final class FeaturedModel {
    public private(set) var items: [MetaItem] = []
    /// Which of `items` is showing.
    public private(set) var index = 0
    /// The featured titles that are saved in the library.
    public private(set) var saved: Set<String> = []

    public init() {}

    public var current: MetaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// The title after the one showing, whose picture is fetched before it is needed.
    public var next: MetaItem? {
        items.count > 1 ? items[(index + 1) % items.count] : nil
    }

    /// Replaces the titles. The one showing stays on show if it is still among them.
    public func update(_ newItems: [MetaItem]) {
        guard newItems != items else { return }
        let showing = current.map(Self.key)
        items = newItems
        index = showing.flatMap { key in newItems.firstIndex { Self.key($0) == key } } ?? 0
    }

    /// Moves on to the next title, and from the last to the first.
    public func advance() {
        guard items.count > 1 else { return }
        index = (index + 1) % items.count
    }

    public func goBack() {
        guard items.count > 1 else { return }
        index = (index + items.count - 1) % items.count
    }

    public func show(_ position: Int) {
        guard items.indices.contains(position), position != index else { return }
        index = position
    }

    // MARK: The library

    public func isSaved(_ item: MetaItem) -> Bool {
        saved.contains(Self.key(item))
    }

    /// Reads again which of the titles are in the library.
    public func refreshSaved(from library: LibraryCenter) async {
        var found = Set<String>()
        for item in items where await library.isSaved(type: item.type, id: item.id) {
            found.insert(Self.key(item))
        }
        if found != saved {
            saved = found
        }
    }

    /// Saves a title to the library, or takes it out.
    public func toggleSaved(_ item: MetaItem, in library: LibraryCenter) async {
        if isSaved(item) {
            await library.remove(type: item.type, id: item.id)
        } else {
            await library.save(item)
        }
        await refreshSaved(from: library)
    }

    // MARK: Turning

    /// How long each title is shown before the banner turns to the next.
    public nonisolated static let turnInterval = Duration.seconds(8)

    /// Whether the banner moves on by itself. Not while it is pointed at (the pointer may be on
    /// its way to a button), not for people who have asked for less motion or have the screen
    /// read to them (a page that changes under them is worse than one that waits), and not
    /// behind another window: while a film plays, the main window would be loading and fading
    /// pictures nobody sees.
    public nonisolated static func turnsByItself(
        count: Int,
        isPointedAt: Bool,
        reducesMotion: Bool,
        isReadAloud: Bool,
        isInKeyWindow: Bool
    ) -> Bool {
        count > 1 && !isPointedAt && !reducesMotion && !isReadAloud && isInKeyWindow
    }

    // MARK: Words

    nonisolated static func key(_ item: MetaItem) -> String {
        "\(item.type.rawValue)|\(item.id)"
    }

    /// The line under the title: rating, year, length, and the first two genres.
    public nonisolated static func facts(for item: MetaItem) -> [String] {
        let genres = item.genres.prefix(2).joined(separator: ", ")
        return [item.ratingText.map { "★ \($0)" }, item.releaseInfo, item.runtime, genres.isEmpty ? nil : genres].compactMap(\.self)
    }

    /// What VoiceOver says for the banner as a whole.
    public nonisolated static func spokenSummary(for item: MetaItem) -> String {
        ([item.name] + facts(for: item).map { $0.replacingOccurrences(of: "★ ", with: "rated ") }).joined(separator: ", ")
    }
}
