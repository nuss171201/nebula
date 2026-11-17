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
    ///     open -g Orbit.app --args -silent YES -play /path/to/file.mkv -seekPreview 0.6
    ///     open -g Orbit.app --args -silent YES -play /path/a.mkv -enqueue /path/b.mkv -panel queue
    ///     open -g Orbit.app --args -silent YES -play /path/to/file.mkv -keys "]]l"   (plain keys, after 2 s)
    ///     open -g Orbit.app --args -silent YES -play /path/to/file.mkv -subtitleSearch "a film's name"
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
            applyPlayerOptions(to: model.player, defaults: defaults)
            if let target = defaults.string(forKey: "open") {
                let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    model.path = [MediaRoute(type: MediaType(rawValue: parts[0]), id: parts[1])]
                }
            }
        }

        /// The arguments that concern the player: what to play, and which of its panels to show.
        @MainActor
        private static func applyPlayerOptions(to player: PlayerCoordinator, defaults: UserDefaults) {
            if let media = defaults.string(forKey: "play") {
                player.play(userInput: media)
            }
            if let media = defaults.string(forKey: "enqueue") {
                player.enqueue(userInput: media)
            }
            if let panel = defaults.string(forKey: "panel") {
                if let tab = PlayerSettingsTab(rawValue: panel) {
                    player.showPlayerSettings(tab)
                } else if panel == "queue" {
                    player.showQueue()
                }
            }
            if let name = defaults.string(forKey: "subtitleSearch") {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    player.searchSubtitleTitles(name)
                }
            }
            if let keys = defaults.string(forKey: "keys") {
                // After the file has had time to open, as most commands need one.
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    player.pressKeys(keys)
                }
            }
            if defaults.object(forKey: "seekPreview") != nil {
                // After the file has had time to open, show the hover preview at this fraction of it.
                let fraction = defaults.double(forKey: "seekPreview")
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    player.showSeekPreview(atFraction: fraction)
                }
            }
        }
    }
#endif
