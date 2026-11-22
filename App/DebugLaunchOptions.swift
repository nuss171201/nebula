#if DEBUG
    import AppUI
    import Foundation
    import MediaCore
    import os
    import PlayerKit

    /// Debug-only launch arguments that open the app in a given state, so a screen can
    /// be checked (or screenshotted) without clicking through the UI:
    ///
    ///     open -g Nebula.app --args -section discover
    ///     open -g Nebula.app --args -search "the office"
    ///     open -g Nebula.app --args -open series:tt0386676
    ///     open -g Nebula.app --args -section addons -install http://127.0.0.1:8123/manifest.json
    ///     open -g Nebula.app --args -silent YES -play /path/to/file.mkv      (or an http(s) address)
    ///     open -g Nebula.app --args -silent YES -engine "profile=fast" -play /path/to/file.mkv
    ///     open -g Nebula.app --args -silent YES -play /path/to/file.mkv -panel audio   (video, audio, subtitles)
    ///     open -g Nebula.app --args -silent YES -play /path/to/file.mkv -seekPreview 0.6
    ///     open -g Nebula.app --args -silent YES -play /path/a.mkv -enqueue /path/b.mkv -panel queue
    ///     open -g Nebula.app --args -silent YES -play /path/to/file.mkv -keys "]]l"   (plain keys, after 2 s)
    ///     open -g Nebula.app --args -silent YES -play /path/to/file.mkv -subtitleSearch "a film's name"
    ///     open -g Nebula.app --args -silent YES -play /path/to/file.mkv -window pictureInPicture   (or mini)
    ///     open -g Nebula.app --args -profile /tmp/scratch -installNow http://127.0.0.1:8123/manifest.json -open movie:tt0063350
    ///     open -g Nebula.app --args -silent YES -profile /tmp/scratch -open movie:tt0063350 -stream 0   (plays the first listed stream)
    ///     open -g Nebula.app --args -profile /tmp/scratch -open series:tt0386676 -episode tt0386676:1:1
    ///     open -g Nebula.app --args -profile /tmp/scratch -open series:tt0386676 -addToLibrary YES -markWatched tt0386676:1:1
    ///     open -g Nebula.app --args -settings shortcuts   (general, playback, streaming, shortcuts, advanced)
    ///     open -g Nebula.app --args -section discover -autoscroll 8   (scrolls by itself; see DebugAutoscroll)
    ///     open -g Nebula.app --args -acknowledgements YES   (opens the Acknowledgements window)
    ///     open -g Nebula.app --args -featured 2   (Home's banner on its third title; -playFeatured YES presses its Play)
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
            if defaults.bool(forKey: "acknowledgements") {
                model.opensAcknowledgementsAtLaunch = true
            }
            if defaults.object(forKey: "autoscroll") != nil {
                // `-autoscroll <seconds>` scrolls the screen's list by itself, three seconds after
                // launch, at `-scrollSpeed <points per second>` (2500 unless given).
                let speed = defaults.object(forKey: "scrollSpeed") != nil ? defaults.double(forKey: "scrollSpeed") : 2500
                DebugAutoscroll.start(
                    after: defaults.object(forKey: "scrollDelay") != nil ? defaults.double(forKey: "scrollDelay") : 3,
                    speed: CGFloat(max(speed, 100)),
                    duration: max(defaults.double(forKey: "autoscroll"), 1)
                )
            }
            applyFeaturedOptions(to: model, defaults: defaults)
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

        /// `-featured <n>` shows the nth title of Home's banner, which turns by itself only in
        /// the window in use (a check's never is); `-playFeatured YES` presses its Play button.
        @MainActor
        private static func applyFeaturedOptions(to model: AppModel, defaults: UserDefaults) {
            guard defaults.object(forKey: "featured") != nil || defaults.bool(forKey: "playFeatured") else { return }
            let position = defaults.integer(forKey: "featured")
            let plays = defaults.bool(forKey: "playFeatured")
            Task {
                for _ in 0 ..< 200 where model.home.featured.items.count <= position {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                model.home.featured.show(position)
                if plays, let item = model.home.featured.current {
                    model.play(item)
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
            applyStreamOptions(to: model, defaults: defaults)
        }

        /// The arguments that press Play or Download, or pick a stream from the list.
        @MainActor
        private static func applyStreamOptions(to model: AppModel, defaults: UserDefaults) {
            if defaults.bool(forKey: "pressPlay") {
                // As soon as the page has streams to choose from (a slow network can take a
                // while): press its Play button.
                Task {
                    for _ in 0 ..< 200 where !model.pressPlayOnShownTitle() {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            if defaults.bool(forKey: "download"), profileDirectory != nil {
                // As soon as the page has something that can be kept: press its Download button.
                // Only ever in a scratch profile, whose downloads folder is its own.
                Task {
                    for _ in 0 ..< 200 where !model.downloadBestStreamOfShownTitle() {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            if let peer = defaults.string(forKey: "peer"), profileDirectory != nil, let port = Int(peer.split(separator: ":").last ?? "") {
                // A scratch profile's engine talks to this machine only and has no tracker to ask:
                // for five minutes, every torrent it has is told where the test's seeder is.
                let address = peer.split(separator: ":").dropLast().joined(separator: ":")
                Task {
                    for _ in 0 ..< 600 {
                        await model.dependencies.streamManager.introduce(peerAt: address, port: port)
                        try? await Task.sleep(for: .milliseconds(500))
                    }
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

        /// `-stats <seconds>`: that long after launch, logs how many frames were dropped or shown
        /// late and how much the engine has buffered. For Scripts/measure-playback.sh.
        @MainActor
        private static func logStats(of player: PlayerCoordinator, after delay: Double) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                guard let model = player.player else { return }
                let names = ["frame-drop-count", "vo-delayed-frame-count", "decoder-frame-drop-count", "demuxer-cache-duration"]
                let values = names.map { "\($0)=\(model.engineProperty($0) ?? "?")" }.joined(separator: " ")
                Logger(subsystem: Branding.current.bundleIdentifier, category: PlayerModel.logCategory)
                    .notice("stats \(values, privacy: .public)")
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
            if defaults.object(forKey: "stats") != nil {
                logStats(of: player, after: max(defaults.double(forKey: "stats"), 1))
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
