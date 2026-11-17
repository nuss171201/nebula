#if DEBUG
    import AppUI
    import Foundation
    import MediaCore
    import PlayerKit

    /// Debug-only launch arguments that open the app in a given state, so a screen can
    /// be checked (or screenshotted) without clicking through the UI:
    ///
    ///     open -g Orbit.app --args -section discover
    ///     open -g Orbit.app --args -search "the office"
    ///     open -g Orbit.app --args -open series:tt0386676
    ///     open -g Orbit.app --args -section addons -install http://127.0.0.1:8123/manifest.json
    ///     open -g Orbit.app --args -silent YES -play /path/to/file.mkv      (or an http(s) address)
    ///     open -g Orbit.app --args -silent YES -engine "profile=fast" -play /path/to/file.mkv
    ///     open -g Orbit.app --args -silent YES -play /path/to/file.mkv -panel audio   (video, audio, subtitles)
    ///
    /// Compiled out of Release builds.
    enum DebugLaunchOptions {
        /// `-silent YES`: the player decodes audio but plays nothing. Use whenever `-play` is
        /// used for a check, so the app never makes a sound the user did not ask for.
        static var isSilent: Bool {
            UserDefaults.standard.bool(forKey: "silent")
        }

        /// `-engine "name=value,name=value"`: extra playback-engine options, for experiments.
        static var engineOptions: [PlayerConfiguration.EngineOption] {
            PlayerConfiguration.EngineOption.parse(UserDefaults.standard.string(forKey: "engine") ?? "")
        }

        @MainActor
        static func apply(to model: AppModel, defaults: UserDefaults = .standard) {
            if let name = defaults.string(forKey: "section"), let section = AppSection(rawValue: name) {
                model.selection = section
            }
            if let query = defaults.string(forKey: "search") {
                model.search.query = query
            }
            if let address = defaults.string(forKey: "install") {
                // Stops at the confirmation sheet; nothing is installed without a click.
                model.addons.addressInput = address
                Task { await model.addons.fetchPendingInstall() }
            }
            if let media = defaults.string(forKey: "play") {
                model.player.play(userInput: media)
            }
            if let panel = defaults.string(forKey: "panel"), let tab = PlayerSettingsTab(rawValue: panel) {
                model.player.showPlayerSettings(tab)
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
