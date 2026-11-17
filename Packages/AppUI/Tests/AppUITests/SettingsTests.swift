@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary
import PlayerKit
import StreamEngine
import Testing

@Suite("App settings")
struct AppSettingsTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("Settings survive being stored and read back")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.appearance = .dark
        settings.startSection = .library
        settings.audioLanguages = ["ja", "en"]
        settings.subtitleMode = .always
        settings.renderQuality = .high
        settings.preferredQualityHeight = 1080
        settings.streamSort = .size
        settings.uploadLimit = 250
        settings.usesDHT = false
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    @Test("What is missing, of the wrong type or unknown reads as the default; numbers are kept in range")
    func lenient() throws {
        #expect(try decode("{}") == AppSettings())
        let settings = try decode("""
        {"appearance": "sepia", "startSection": 7, "autoplaysNextEpisode": false, "nextEpisodeCountdown": 500,
         "cacheLimitGigabytes": 0.01, "connectionsLimit": 5, "uploadLimit": -3, "audioLanguages": "en",
         "subtitleLanguages": ["de"], "fromTheFuture": {"a": 1}}
        """)
        #expect(settings.appearance == .system)
        #expect(settings.startSection == .home)
        #expect(!settings.autoplaysNextEpisode)
        #expect(settings.nextEpisodeCountdown == 60)
        #expect(settings.cacheLimitGigabytes == 1)
        #expect(settings.connectionsLimit == 20)
        #expect(settings.uploadLimit == 0)
        #expect(settings.audioLanguages == nil)
        #expect(settings.subtitleLanguages == ["de"])
    }

    @Test("Languages follow the system until the user names their own")
    func languages() {
        var settings = AppSettings()
        let system = settings.trackPreferences(systemLanguages: ["fr-FR", "en-GB"])
        #expect(system.audioLanguages == ["fr", "en"])
        #expect(system.subtitleLanguages == ["fr", "en"])

        settings.audioLanguages = ["ja"]
        settings.subtitleMode = .off
        let own = settings.trackPreferences(systemLanguages: ["fr-FR"])
        #expect(own.audioLanguages == ["ja"])
        #expect(own.subtitleLanguages == ["fr"])
        #expect(own.subtitleMode == .off)
    }

    @Test("Limits reach the stream engine in its units, and the cache in bytes")
    func engine() {
        var settings = AppSettings()
        settings.connectionsLimit = 80
        settings.downloadLimit = 2000
        settings.uploadLimit = 100
        settings.usesLocalDiscovery = false
        settings.cacheLimitGigabytes = 2.5
        let engine = settings.engineSettings(basedOn: TorrentEngineSettings(userAgent: "Tests/1.0"))
        #expect(engine.connectionsLimit == 80)
        #expect(engine.downloadRateLimit == 2_048_000)
        #expect(engine.uploadRateLimit == 102_400)
        #expect(engine.usesDHT)
        #expect(!engine.usesLocalDiscovery)
        #expect(engine.mapsPorts)
        #expect(engine.userAgent == "Tests/1.0")
        #expect(settings.cachePolicy.maximumBytes == 2_684_354_560)
        #expect(settings.preferredQuality == nil)
    }

    @Test("An engine that was told to stay on this machine is not opened to the network by a setting")
    func staysLocal() {
        let settings = AppSettings()
        #expect(settings.usesDHT && settings.usesLocalDiscovery && settings.mapsPorts)
        let base = TorrentEngineSettings.loopback()
        let engine = settings.engineSettings(basedOn: base)
        #expect(!engine.usesDHT)
        #expect(!engine.usesLocalDiscovery)
        #expect(!engine.mapsPorts)
        #expect(engine.listenInterfaces == base.listenInterfaces)
    }
}

@Suite("Settings helpers")
struct SettingsHelperTests {
    private let english = Locale(identifier: "en_US")

    @Test("Languages are understood by code or name, in the order typed, without repeats", arguments: [
        ("en, ja", ["en", "ja"]),
        ("English, Japanese", ["en", "ja"]),
        ("  jpn ;FRE, pt-BR\nenglish", ["ja", "fr", "pt", "en"]),
        ("en, eng, English", ["en"]),
        ("Klingon?, xx, 12, the, , de", ["de"]),
        ("", []),
    ])
    func languages(text: String, expected: [String]) {
        #expect(LanguageList.parse(text, locale: english) == expected)
    }

    @Test("Names are also understood in the user's own language, and codes are shown as names")
    func localisedNames() {
        let german = Locale(identifier: "de_DE")
        #expect(LanguageList.parse("Deutsch, Französisch, Japanese", locale: german) == ["de", "fr", "ja"])
        #expect(LanguageList.names(of: ["en", "ja"], locale: english) == "English, Japanese")
        #expect(LanguageList.names(of: [], locale: english).isEmpty)
    }

    @Test("A config file's line says what became of it")
    func configSummary() {
        var file = EngineConfigReport.File(url: URL(filePath: "/tmp/mpv.conf"))
        #expect(file.summary(noun: "option") == "Not there")
        file.exists = true
        #expect(file.summary(noun: "option") == "Nothing in use")
        file.usedCount = 1
        #expect(file.summary(noun: "option") == "1 option in use")
        file.usedCount = 3
        file.ignored = [IgnoredConfigLine(number: 2, text: "vo=gpu", reason: "The app controls this itself.")]
        #expect(file.summary(noun: "shortcut") == "3 shortcuts in use, 1 line left out")
        file.problem = "The file could not be read."
        #expect(file.summary(noun: "option") == "The file could not be read.")
    }
}

@MainActor
private struct SettingsFixture {
    let store: SettingsStore
    let coordinator: PlayerCoordinator
    let manager: StreamManager
    let nextEpisode: NextEpisodeController
    let folder: URL

    init(resumes: Bool = true, engineOptions: [PlayerConfiguration.EngineOption] = []) throws {
        store = try SettingsStore(database: .inMemory())
        coordinator = PlayerCoordinator(
            configuration: PlayerConfiguration(
                userAgent: "AppUITests/1.0",
                logSubsystem: "test.appui",
                videoOutput: .none,
                playsAudio: false,
                resumesPlayback: resumes,
                additionalEngineOptions: engineOptions
            ),
            presentsWindow: false
        )
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("settings-tests-\(UUID().uuidString)", isDirectory: true)
        manager = StreamManager(settings: .loopback(), cache: StreamCache(directory: folder.appendingPathComponent("cache")))
        nextEpisode = NextEpisodeController(
            coordinator: coordinator,
            streamPlayer: StreamPlayer(coordinator: coordinator, manager: manager),
            client: AddonClient(http: URLSessionHTTPClient(userAgent: "Tests/1.0"))
        )
    }

    func model(readingConfig: Bool = false) -> SettingsModel {
        SettingsModel(
            store: store,
            coordinator: coordinator,
            streamManager: manager,
            nextEpisode: nextEpisode,
            configFolder: readingConfig ? EngineConfigFolder(directory: folder) : nil,
            sleep: { _ in }
        )
    }

    func write(_ text: String, to name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    func tearDown() async {
        await manager.shutdown()
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor
@Suite("Settings model")
struct SettingsModelTests {
    @Test("Stored settings are applied to the player, autoplay, the stream engine and the cache at launch")
    func loadApplies() async throws {
        let fixture = try SettingsFixture()
        var stored = AppSettings()
        stored.audioLanguages = ["ja"]
        stored.subtitleMode = .always
        stored.renderQuality = .high
        stored.autoplaysNextEpisode = false
        stored.nextEpisodeCountdown = 20
        stored.uploadLimit = 50
        stored.connectionsLimit = 64
        stored.cacheLimitGigabytes = 3
        try await fixture.store.set(stored, for: SettingsKeys.app)

        let model = fixture.model()
        #expect(!model.hasLoaded)
        await model.load()
        await model.waitForSave()
        #expect(model.hasLoaded)
        #expect(model.settings == stored)
        let configuration = fixture.coordinator.configuration
        #expect(configuration.trackPreferences.audioLanguages == ["ja"])
        #expect(configuration.trackPreferences.subtitleMode == .always)
        #expect(configuration.renderQuality == .high)
        #expect(configuration.resumesPlayback)
        // What is not a setting is kept as the app was started with.
        #expect(configuration.userAgent == "AppUITests/1.0")
        #expect(!configuration.playsAudio)
        #expect(!fixture.nextEpisode.isEnabled)
        #expect(fixture.nextEpisode.countdown == 20)
        let engine = await fixture.manager.settings
        #expect(engine.uploadRateLimit == 51200)
        #expect(engine.connectionsLimit == 64)
        #expect(!engine.usesDHT)
        #expect(await fixture.manager.cachePolicy.maximumBytes == 3 << 30)
        await fixture.tearDown()
    }

    @Test("A change applies at once, is stored, and is there for the next launch")
    func changeAppliesAndSaves() async throws {
        let fixture = try SettingsFixture()
        let model = fixture.model()
        await model.load()
        #expect(model.settings == AppSettings())
        #expect(fixture.nextEpisode.isEnabled)

        model.settings.autoplaysNextEpisode = false
        model.settings.resumesPlayback = false
        model.settings.downloadLimit = 10
        #expect(!fixture.nextEpisode.isEnabled)
        #expect(!fixture.coordinator.configuration.resumesPlayback)
        await model.waitForSave()
        #expect(await fixture.manager.settings.downloadRateLimit == 10240)

        let next = fixture.model()
        await next.load()
        #expect(!next.settings.autoplaysNextEpisode)
        #expect(!next.settings.resumesPlayback)
        #expect(next.settings.downloadLimit == 10)

        next.resetToDefaults()
        await next.waitForSave()
        #expect(next.settings == AppSettings())
        #expect(fixture.nextEpisode.isEnabled)
        #expect(try await fixture.store.value(for: SettingsKeys.app) == AppSettings())
        await fixture.tearDown()
    }

    @Test("A player that was started not to resume (a silent check) does not, whatever the setting")
    func resumeStaysOff() async throws {
        let fixture = try SettingsFixture(resumes: false)
        let model = fixture.model()
        await model.load()
        #expect(model.settings.resumesPlayback)
        #expect(!fixture.coordinator.configuration.resumesPlayback)
        await fixture.tearDown()
    }

    @Test("Choices made in the player's panel are kept for the next video and the next launch")
    func playerDefaults() async throws {
        let fixture = try SettingsFixture()
        let model = fixture.model()
        await model.load()
        #expect(fixture.coordinator.configuration.defaults == PlayerDefaults())

        var defaults = PlayerDefaults()
        defaults.subtitleScale = 1.4
        defaults.normalizesLoudness = true
        fixture.coordinator.onPlayerDefaultsChanged?(defaults)
        #expect(fixture.coordinator.configuration.defaults == defaults)
        await model.waitForSave()
        #expect(try await fixture.store.value(for: SettingsKeys.playerDefaults) == defaults)

        // A later settings change does not lose them.
        model.settings.renderQuality = .high
        #expect(fixture.coordinator.configuration.defaults == defaults)

        let next = fixture.model()
        await next.load()
        #expect(fixture.coordinator.configuration.defaults == defaults)
        await fixture.tearDown()
    }

    @Test("The engine's config files add options and keys; switching them off takes both away")
    func configFiles() async throws {
        let fixture = try SettingsFixture(engineOptions: [.init("deband", "no")])
        try fixture.write("deband=yes\nvo=null\ninterpolation\n", to: "mpv.conf")
        try fixture.write("g cycle mute\nr run rm\nSPACE ignore\n", to: "input.conf")
        let model = fixture.model(readingConfig: true)
        await model.load()

        // The file's options come first, so what the app was started with still has the last word.
        #expect(fixture.coordinator.configuration.additionalEngineOptions == [
            .init("deband", "yes"), .init("interpolation", "yes"), .init("deband", "no"),
        ])
        #expect(model.configReport.optionsFile?.exists == true)
        #expect(model.configReport.optionsFile?.usedCount == 2)
        #expect(model.configReport.optionsFile?.ignored.map(\.number) == [2])
        #expect(model.configReport.bindingsFile?.usedCount == 2)
        #expect(model.configReport.bindingsFile?.ignored.map(\.number) == [2])
        let keys = fixture.coordinator.keyBindings
        #expect(keys.command(for: KeyChord(.character("g"))) == .toggleMute)
        #expect(keys.command(for: KeyChord(.space)) == nil)
        #expect(keys.command(for: KeyChord(.character("k"))) == .togglePause)
        #expect(!model.shortcuts.hasChanges)

        model.settings.readsEngineConfigFiles = false
        #expect(fixture.coordinator.configuration.additionalEngineOptions == [.init("deband", "no")])
        #expect(fixture.coordinator.keyBindings == .standard)

        // Edited and read again.
        model.settings.readsEngineConfigFiles = true
        try fixture.write("hwdec=no\n", to: "mpv.conf")
        try FileManager.default.removeItem(at: fixture.folder.appendingPathComponent("input.conf"))
        await model.reloadConfigFiles()
        #expect(fixture.coordinator.configuration.additionalEngineOptions.first == .init("hwdec", "no"))
        #expect(model.configReport.bindingsFile?.exists == false)
        #expect(fixture.coordinator.keyBindings == .standard)
        await model.waitForSave()
        await fixture.tearDown()
    }

    @Test("No files, a folder in a file's place and a file too large to be a config file are all harmless")
    func configFolderEdges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = EngineConfigFolder(directory: directory)
        var report = folder.load()
        #expect(report.options.isEmpty && report.bindings.isEmpty)
        #expect(report.optionsFile?.exists == false)

        try folder.create()
        try FileManager.default.createDirectory(at: folder.optionsFileURL, withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "a"), count: EngineConfigFolder.maximumFileSize + 1).write(to: folder.bindingsFileURL)
        report = folder.load()
        #expect(report.optionsFile?.exists == false)
        #expect(report.bindingsFile?.exists == true)
        #expect(report.bindingsFile?.problem == "The file is too large to be a config file.")
        #expect(report.bindings.isEmpty)
    }
}

@MainActor
@Suite("Shortcut editor")
struct ShortcutsModelTests {
    private func row(_ model: ShortcutsModel, _ title: String) -> ShortcutsModel.Row? {
        model.groups.flatMap(\.rows).first { $0.action.title == title }
    }

    private func action(_ title: String) throws -> ShortcutAction {
        try #require(ShortcutAction.all.first { $0.title == title })
    }

    @Test("It starts with the standard keys, grouped")
    func standard() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        await model.load()
        #expect(model.groups.map(\.title) == ["Playback", "Navigation", "Sound", "Subtitles", "Window", "Other"])
        #expect(row(model, "Play / Pause")?.chords == [KeyChord(.character("k")), KeyChord(.space)])
        #expect(row(model, "Forward 30 Seconds")?.chords == [KeyChord(.rightArrow, .shift)])
        #expect(row(model, "Next Audio Track")?.isChanged == false)
        #expect(!model.hasChanges)
        #expect(model.bindings == .standard)
        await fixture.tearDown()
    }

    @Test("A new key is bound, reaches the player, and is there after a relaunch")
    func assign() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        await model.load()
        let mute = try action("Mute")
        #expect(model.assign(KeyChord(.character("u"), .control), to: mute))
        #expect(model.notice == nil)
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("m")), KeyChord(.character("u"), .control)])
        #expect(row(model, "Mute")?.isChanged == true)
        #expect(model.hasChanges)
        #expect(fixture.coordinator.keyBindings.command(for: KeyChord(.character("u"), .control)) == .toggleMute)
        await model.waitForSave()

        let next = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        await next.load()
        #expect(next.bindings.command(for: KeyChord(.character("u"), .control)) == .toggleMute)
        #expect(next.hasChanges)
        await fixture.tearDown()
    }

    @Test("A key that is taken moves, and the editor says from where; the app's own keys are refused")
    func conflicts() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        let mute = try action("Mute")
        #expect(model.assign(KeyChord(.character("f")), to: mute))
        #expect(model.notice == "F was taken from “Full Screen”.")
        #expect(row(model, "Full Screen")?.chords == [KeyChord(.returnKey)])
        #expect(row(model, "Full Screen")?.isChanged == true)
        #expect(model.bindings.command(for: KeyChord(.character("f"))) == .toggleMute)

        // Assigning what it already has changes nothing and says nothing.
        #expect(model.assign(KeyChord(.character("m")), to: mute))
        #expect(model.notice == nil)

        #expect(!model.assign(KeyChord(.character("q"), .command), to: mute))
        #expect(model.notice == "⌘Q is used for quitting the app and cannot be a player shortcut.")
        #expect(model.bindings.command(for: KeyChord(.character("q"), .command)) == nil)
        await model.waitForSave()
        await fixture.tearDown()
    }

    @Test("Keys can be removed; one action or everything can be put back")
    func removeAndReset() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        let pause = try action("Play / Pause")
        let mute = try action("Mute")
        model.remove(KeyChord(.space))
        model.assign(KeyChord(.character("p")), to: pause)
        model.assign(KeyChord(.character("k")), to: mute)
        #expect(row(model, "Play / Pause")?.chords == [KeyChord(.character("p"))])

        // Space comes back and P goes; K stays with Mute, where the user put it.
        model.reset(pause)
        #expect(row(model, "Play / Pause")?.chords == [KeyChord(.space)])
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("k")), KeyChord(.character("m"))])
        #expect(model.hasChanges)

        model.resetAll()
        #expect(model.bindings == .standard)
        #expect(!model.hasChanges)
        await model.waitForSave()
        #expect(try await fixture.store.value(for: LibraryPlayerMemory.keyBindingOverridesKey).isEmpty)
        await fixture.tearDown()
    }

    @Test("Recording takes the next key press; Escape cancels")
    func recording() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        let mute = try action("Mute")
        #expect(!model.record(KeyChord(.character("j"))))

        model.toggleRecording(for: mute)
        #expect(model.recordingActionID == mute.id)
        #expect(model.record(KeyChord(.escape)))
        #expect(model.recordingActionID == nil)
        #expect(model.bindings == .standard)

        model.toggleRecording(for: mute)
        #expect(model.record(KeyChord(.character("j"))))
        #expect(model.recordingActionID == nil)
        #expect(model.bindings.command(for: KeyChord(.character("j"))) == .toggleMute)

        model.toggleRecording(for: mute)
        model.toggleRecording(for: mute)
        #expect(model.recordingActionID == nil)
        await model.waitForSave()
        await fixture.tearDown()
    }

    @Test("A bindings file sits under the user's changes and is what Reset goes back to")
    func fileLayer() async throws {
        let fixture = try SettingsFixture()
        let model = ShortcutsModel(store: fixture.store, coordinator: fixture.coordinator)
        let file = InputConfigFile.parse("g cycle mute\nRIGHT seek 10\nm ignore").bindings
        model.setFileBindings(file)
        #expect(!model.hasChanges)
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("g"))])
        // A command the editor does not list gets a row of its own.
        #expect(row(model, "Forward 10 Seconds")?.chords == [KeyChord(.rightArrow)])
        #expect(row(model, "Forward 5 Seconds")?.chords == [])

        let mute = try action("Mute")
        model.assign(KeyChord(.character("u")), to: mute)
        #expect(model.hasChanges)
        model.resetAll()
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("g"))])

        // Without the file the user's own changes remain.
        model.assign(KeyChord(.character("u")), to: mute)
        model.setFileBindings([:])
        #expect(row(model, "Mute")?.chords == [KeyChord(.character("m")), KeyChord(.character("u"))])
        #expect(row(model, "Forward 10 Seconds") == nil)
        await model.waitForSave()
        await fixture.tearDown()
    }
}
