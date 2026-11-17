#if DEBUG
    import AppUI
    import Foundation
    import MediaCore

    /// Debug-only launch arguments that open the app in a given state, so a screen can
    /// be checked (or screenshotted) without clicking through the UI:
    ///
    ///     open -g Orbit.app --args -section discover
    ///     open -g Orbit.app --args -search "the office"
    ///     open -g Orbit.app --args -open series:tt0386676
    ///
    /// Compiled out of Release builds.
    enum DebugLaunchOptions {
        @MainActor
        static func apply(to model: AppModel, defaults: UserDefaults = .standard) {
            if let name = defaults.string(forKey: "section"), let section = AppSection(rawValue: name) {
                model.selection = section
            }
            if let query = defaults.string(forKey: "search") {
                model.search.query = query
            }
            if let target = defaults.string(forKey: "open") {
                let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    model.path = [MediaRoute(type: MediaType(rawValue: parts[0]), id: parts[1])]
                }
            }
        }
    }
#endif
