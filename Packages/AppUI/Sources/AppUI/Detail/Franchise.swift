import Foundation
import MediaCore

/// One title of a run of titles that follow one another: a season of an anime that its
/// catalog lists as a title of its own, or a film and its sequels.
public struct FranchiseEntry: Identifiable, Hashable, Sendable {
    public var item: MetaItem
    /// What the entry is called among its neighbours: "Season 2", or a film's name.
    public var label: String

    public var id: String {
        item.id
    }
}

/// Reading the links by which a catalog says "this comes before that".
///
/// Some catalogs (anime ones above all) list every season as a separate title, each with one
/// season of episodes, and join them with links in the category "Franchise" named
/// "Sequel: …" and "Prequel: …". Followed in both directions they give the whole run.
public enum Franchise {
    public enum Relation: Sendable, Equatable {
        case prequel, sequel
    }

    /// Where a link of that kind leads, if the title has one. Other relations (side stories,
    /// spin-offs) are not part of the run and are left out.
    public static func neighbour(_ relation: Relation, of item: MetaItem) -> MediaRoute? {
        let prefix = relation == .prequel ? "prequel" : "sequel"
        for link in item.links where link.category.caseInsensitiveCompare("Franchise") == .orderedSame {
            let kind = link.name.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if kind == prefix, let url = link.url, let route = route(of: url) {
                return route
            }
        }
        return nil
    }

    /// The title a link points to: add-ons write these as `stremio:///detail/<type>/<id>`
    /// (the protocol's own form of address for a title's page). Anything else is no title.
    static func route(of url: URL) -> MediaRoute? {
        guard url.scheme?.lowercased() == "stremio" else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "detail", !parts[1].isEmpty else { return nil }
        // An id may itself contain slashes only by mistake; what follows the type is taken whole.
        let id = parts[2...].joined(separator: "/")
        return id.isEmpty ? nil : MediaRoute(type: MediaType(rawValue: String(parts[1])), id: id)
    }

    /// The run with what each title is called in it: series are numbered as seasons in the
    /// order they come; anything else (a film between two seasons) keeps its name.
    public static func entries(for items: [MetaItem]) -> [FranchiseEntry] {
        var season = 0
        return items.map { item in
            guard item.type == .series || item.type == .anime else {
                return FranchiseEntry(item: item, label: item.name)
            }
            season += 1
            return FranchiseEntry(item: item, label: "Season \(season)")
        }
    }
}
