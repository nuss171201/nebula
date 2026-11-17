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
    ///     open -g Orbit.app --args -silent YES -play /path/to/file.mkv -window pictureInPicture   (or mini)
    ///     open -g Orbit.app --args -profile /tmp/scratch -installNow http://127.0.0.1:8123/manifest.json -open movie:tt0063350
    ///     open -g Orbit.app --args -silent YES -profile /tmp/scratch -open movie:tt0063350 -stream 0   (plays the first listed stream)
    ///     open -g Orbit.app --args -profile /tmp/scratch -open series:tt0386676 -episode tt0386676:1:1
    ///     open -g Orbit.app --args -profile /tmp/scratch -open series:tt0386676 -addToLibrary YES -markWatched tt0386676:1:1
    ///     open -g Orbit.app --args -settings shortcuts   (general, playback, streaming, shortcuts, advanced)
    ///
    /// Compiled out of Release builds.
    enum DebugLaunchOptions {
        /// `-silent YES`: the player decodes audio but plays nothing. Use whenever `-play` is
        /// used for a check, so the app never makes a sound the user did not ask for.
        static var isSilent: Bool {
            UserDefaults.standard.bool(forKey: "silent")
        }

        /// `-profile <folder>`: keep the database and caches there instead of in the user's own
        /// folders, so a check can install add-ons and stream without touching their data.
        static var profileDirectory: URL? {
            UserDefaults.standard.string(forKey: "profile").map { URL(fileURLWithPath: $0, isDirectory: true) }
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
            if let name = defaults.string(forKey: "settings"), let tab = SettingsTab(rawValue: name) {
                model.settings.selectedTab = tab
                model.opensSettingsAtLaunch = true
            }
            if let query = defaults.string(forKey: "search") {
                model.search.query = query
            }
            if let address = defaults.string(forKey: "install") {
                // Stops at the confirmation sheet; nothing is installed without a click.
                model.addons.addressInput = address
                Task { await model.addons.fetchPendingInstall() }
            }
            applyLibraryOptions(to: model, defaults: defaults)
            // Not now: this runs while SwiftUI is still creating the app's state, and anything
            // that lays out a window from here (resizing the player's, for one) re-enters
            // SwiftUI's update and aborts the app.
            Task { @MainActor in
                applyPlayerOptions(to: model.player, defaults: defaults)
            }
            if let target = defaults.string(forKey: "open") {
                let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    model.path = [MediaRoute(type: MediaType(rawValue: parts[0]), id: parts[1])]
                }
            }
        }

        /// The arguments that install an add-on, change the library or pick a stream, as clicks would.
        @MainActor
        private static func applyLibraryOptions(to model: AppModel, defaults: UserDefaults) {
            if let address = defaults.string(forKey: "installNow"), profileDirectory != nil {
                // Without the confirmation, and therefore only ever into a scratch profile.
                Task {
                    // The registry sets itself up (and installs the defaults) when the window appears.
                    for _ in 0 ..< 100 where !model.registry.isReady {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    if let addon = try? await model.registry.preview(address: address) {
                        try? await model.registry.install(addon)
                    }
                }
            }
            if defaults.bool(forKey: "addToLibrary") || defaults.string(forKey: "markWatched") != nil, profileDirectory != nil {
                // Once the detail page has loaded. Only ever in a scratch profile.
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    if defaults.bool(forKey: "addToLibrary") {
                        await model.saveShownTitleToLibrary()
                    }
                    if let videoID = defaults.string(forKey: "markWatched") {
                        await model.markShownVideoWatched(withID: videoID)
                    }
                }
            }
            if let episode = defaults.string(forKey: "episode") {
                // Once the detail page has had time to load: show this episode's streams.
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    model.showStreamsOfEpisode(withID: episode)
                }
            }
            if defaults.object(forKey: "stream") != nil {
                // Once the streams have had time to arrive: play the one at this place in the list.
                let index = defaults.integer(forKey: "stream")
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    model.playListedStream(at: index)
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
            if let name = defaults.string(forKey: "window"), let mode = PlayerWindowMode(rawValue: name) {
                player.setWindowMode(mode)
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
