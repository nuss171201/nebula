/// A top-level destination in the sidebar.
public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case home
    case discover
    case library
    case calendar
    case addons

    public var id: Self { self }

    public var title: String {
        switch self {
        case .home: "Home"
        case .discover: "Discover"
        case .library: "Library"
        case .calendar: "Calendar"
        case .addons: "Add-ons"
        }
    }

    /// SF Symbol name for the sidebar row.
    public var systemImage: String {
        switch self {
        case .home: "house"
        case .discover: "safari"
        case .library: "books.vertical"
        case .calendar: "calendar"
        case .addons: "puzzlepiece.extension"
        }
    }

    /// What the section shows before it has any content.
    public var emptyStateMessage: String {
        switch self {
        case .home: "Catalogs from your add-ons will appear here."
        case .discover: "Browse catalogs by type, genre and year."
        case .library: "Titles you save and your watch history will appear here."
        case .calendar: "Upcoming episodes for series in your library will appear here."
        case .addons: "Install add-ons by URL to add catalogs, metadata and subtitles."
        }
    }
}
