/// A top-level destination in the sidebar.
public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case home
    case discover
    case anime
    case library
    case downloads
    case calendar
    case addons
    case settings

    public var id: Self { self }

    public var title: String {
        switch self {
        case .home: "Home"
        case .discover: "Discover"
        case .anime: "Anime"
        case .library: "Library"
        case .downloads: "Downloads"
        case .calendar: "Calendar"
        case .addons: "Add-ons"
        case .settings: "Settings"
        }
    }

    /// SF Symbol name for the sidebar row.
    public var systemImage: String {
        switch self {
        case .home: "house"
        case .discover: "safari"
        case .anime: "sparkles.tv"
        case .library: "books.vertical"
        case .downloads: "arrow.down.circle"
        case .calendar: "calendar"
        case .addons: "puzzlepiece.extension"
        case .settings: "gearshape"
        }
    }
}
