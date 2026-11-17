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
}
