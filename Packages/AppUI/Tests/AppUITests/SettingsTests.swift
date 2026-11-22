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
        settings.streamListStyle = .fullList
        settings.maximumStreamGigabytes = 20
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

    @Test("The connection's speed is shown as connections are advertised; Play says what is wrong with the best there is")
    func streamingTexts() {
        #expect(StreamingSettingsPane.speedText(nil) == "Not measured yet")
        #expect(StreamingSettingsPane.speedText(0) == "Not measured yet")
        #expect(StreamingSettingsPane.speedText(4_750_000) == "38 Mbit/s")
        #expect(StreamingSettingsPane.speedText(500_000).hasSuffix(" Mbit/s"))
        #expect(StreamListView.caution(for: .good) == nil)
        for standing in [StreamPick.Standing.large, .fewPeers, .tooHeavy, .overLimit, .wrongLanguage] {
            #expect(StreamListView.caution(for: standing)?.isEmpty == false)
        }
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
struct SettingsFixture {
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

    @Test("What Play goes by: the user's languages and limits, and a speed learned from streams and kept between launches")
    func picker() async throws {
        let fixture = try SettingsFixture()
        let model = fixture.model()
        await model.load()
        #expect(model.measuredSpeed == nil)
        #expect(model.pickerContext.measuredSpeed == nil)
        #expect(model.pickerContext.maximumQuality == nil && model.pickerContext.maximumSize == nil)
        #expect(model.settings.streamListStyle == .playButton)

        model.settings.audioLanguages = ["de", "en"]
        model.settings.preferredQualityHeight = 1080
        model.settings.maximumStreamGigabytes = 10
        let context = model.pickerContext
        #expect(context.languages == ["de", "en"])
        #expect(context.maximumQuality == .hd1080)
        #expect(context.maximumSize == 10_737_418_240)

        // A stream held 5 MB/s; a slower one later lowers the figure only a little; a faster one raises it at once.
        model.noteStreamSession(bestRate: 5_000_000)
        #expect(model.measuredSpeed == 5_000_000)
        model.noteStreamSession(bestRate: 1_000_000)
        #expect(model.measuredSpeed == 4_500_000)
        model.noteStreamSession(bestRate: 0)
        #expect(model.measuredSpeed == 4_500_000)
        model.noteStreamSession(bestRate: 9_000_000)
        #expect(model.pickerContext.measuredSpeed == 9_000_000)
        await model.waitForSave()

        let next = fixture.model()
        await next.load()
        #expect(next.measuredSpeed == 9_000_000)
        #expect(next.settings.maximumStreamGigabytes == 10)

        next.forgetMeasuredSpeed()
        await next.waitForSave()
        #expect(next.measuredSpeed == nil)
        let afterwards = fixture.model()
        await afterwards.load()
        #expect(afterwards.measuredSpeed == nil)
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
