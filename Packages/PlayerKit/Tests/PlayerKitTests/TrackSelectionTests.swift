import Foundation
@testable import PlayerKit
import Testing

@Suite("Track selection")
struct TrackSelectionTests {
    private func audio(_ number: Int, _ language: String?, _ title: String? = nil, selected: Bool = false, channels: Int? = nil) -> MediaTrack {
        MediaTrack(kind: .audio, number: number, title: title, language: language, isSelected: selected, channelCount: channels)
    }

    private func subtitle(_ number: Int, _ language: String?, _ title: String? = nil, forced: Bool = false) -> MediaTrack {
        MediaTrack(kind: .subtitle, number: number, title: title, language: language, isForced: forced)
    }

    private func preferences(
        audio: [String],
        subtitles: [String]? = nil,
        mode: TrackPreferences.SubtitleMode = .automatic
    ) -> TrackPreferences {
        TrackPreferences(audioLanguages: audio, subtitleLanguages: subtitles ?? audio, subtitleMode: mode)
    }

    @Test("Language tags that mean the same language match", arguments: [
        ("en", "eng", true), ("EN-us", "eng", true), ("fr", "fra", true), ("fre", "fra", true), ("ger", "de", true),
        ("chi", "zho", true), ("zh-Hans", "chi", true), ("en", "fr", false), ("und", "und", false), ("", "en", false),
    ])
    func languageMatching(lhs: String, rhs: String, expected: Bool) {
        #expect(LanguageMatcher.matches(lhs, rhs) == expected)
    }

    @Test("Titles are matched to languages by whole words", arguments: [
        ("English", "en", true), ("Eng", "en", true), ("ENG 5.1", "en", true), ("[EN] Stereo", "en", true),
        ("Français", "fr", true), ("Deutsch (DTS)", "de", true), ("日本語", "ja", true), ("German", "ger", true),
        ("Surround", "en", false), ("Frengo", "fr", false), ("Dengue", "en", false), ("", "en", false),
    ])
    func titleMatching(title: String, language: String, expected: Bool) {
        #expect(LanguageMatcher.title(title, names: language) == expected)
    }

    @Test("Display names and canonical keys")
    func names() {
        #expect(LanguageMatcher.displayName(for: "fra", locale: Locale(identifier: "en")) == "French")
        #expect(LanguageMatcher.displayName(for: "ger", locale: Locale(identifier: "en")) == "German")
        #expect(LanguageMatcher.displayName(for: nil) == nil)
        #expect(LanguageMatcher.canonical("eng") == "en")
        #expect(LanguageMatcher.canonical("und") == nil)
        #expect(TrackPreferences.system(preferredLanguages: ["en-IN", "hi-IN", "en-GB"]).audioLanguages == ["en", "hi"])
    }

    @Test("Audio follows the preference order by language tag")
    func audioByTag() {
        let tracks = [audio(1, "fra", selected: true), audio(2, "deu"), audio(3, "eng")]
        #expect(TrackSelector.selection(tracks: tracks, preferences: preferences(audio: ["en", "de"]), remembered: nil).audio == 3)
        #expect(TrackSelector.selection(tracks: tracks, preferences: preferences(audio: ["hi", "de"]), remembered: nil).audio == 2)
        // Nothing preferred is present: leave the file's default alone.
        #expect(TrackSelector.selection(tracks: tracks, preferences: preferences(audio: ["hi"]), remembered: nil).audio == nil)
    }

    @Test("An untagged track is found by its title, but a tagged one wins")
    func audioByTitle() {
        let untagged = [audio(1, "fra", selected: true), audio(2, nil, "English"), audio(3, nil)]
        #expect(TrackSelector.selection(tracks: untagged, preferences: preferences(audio: ["en"]), remembered: nil).audio == 2)

        let both = [audio(1, nil, "Eng"), audio(2, "eng", "Stereo")]
        #expect(TrackSelector.selection(tracks: both, preferences: preferences(audio: ["en"]), remembered: nil).audio == 2)

        // A title in another language's words is not a match.
        let misleading = [audio(1, "fra", "English dub credits", selected: true)]
        #expect(TrackSelector.selection(tracks: misleading, preferences: preferences(audio: ["en"]), remembered: nil).audio == nil)
    }

    @Test("Commentary and description tracks are passed over when a regular one exists")
    func secondaryAudio() {
        let tracks = [audio(1, "eng", "Director's Commentary"), audio(2, "eng", "Audio Description"), audio(3, "eng", "5.1")]
        #expect(TrackSelector.selection(tracks: tracks, preferences: preferences(audio: ["en"]), remembered: nil).audio == 3)
        let onlyCommentary = [audio(1, "fra"), audio(2, "eng", "Commentary")]
        #expect(TrackSelector.selection(tracks: onlyCommentary, preferences: preferences(audio: ["en"]), remembered: nil).audio == 2)
    }

    @Test("What the user chose last time beats the preferences")
    func rememberedAudio() {
        let tracks = [audio(1, "eng", "Stereo", channels: 2), audio(2, "eng", "Surround", channels: 6), audio(3, "jpn")]
        let japanese = RememberedTracks(audio: TrackDescriptor(language: "ja"))
        #expect(TrackSelector.selection(tracks: tracks, preferences: preferences(audio: ["en"]), remembered: japanese).audio == 3)

        // Same language twice: the title and channel layout pick the right one.
        let surround = RememberedTracks(audio: TrackDescriptor(language: "eng", title: "Surround", channelCount: 6))
        #expect(TrackSelector.selection(tracks: tracks, preferences: preferences(audio: ["ja"]), remembered: surround).audio == 2)

        // The remembered language is missing from this file: fall back to the preferences.
        let german = RememberedTracks(audio: TrackDescriptor(language: "de"))
        #expect(TrackSelector.selection(tracks: tracks, preferences: preferences(audio: ["ja"]), remembered: german).audio == 3)
    }

    @Test("Automatic subtitles appear only when the sound is not understood")
    func automaticSubtitles() {
        let subtitles = [subtitle(1, "spa"), subtitle(2, "eng")]
        let english = preferences(audio: ["en"])

        let foreign = [audio(1, "jpn", selected: true)] + subtitles
        #expect(TrackSelector.selection(tracks: foreign, preferences: english, remembered: nil).subtitle == .track(2))

        let understood = [audio(1, "eng", selected: true)] + subtitles
        #expect(TrackSelector.selection(tracks: understood, preferences: english, remembered: nil).subtitle == .off)

        // Understood through the title of an untagged track.
        let untagged = [audio(1, nil, "English", selected: true)] + subtitles
        #expect(TrackSelector.selection(tracks: untagged, preferences: english, remembered: nil).subtitle == .off)

        // No subtitle in a preferred language: none is better than a random one.
        let onlySpanish = [audio(1, "jpn", selected: true), subtitle(1, "spa")]
        #expect(TrackSelector.selection(tracks: onlySpanish, preferences: english, remembered: nil).subtitle == .off)

        // A file without subtitles needs no decision.
        #expect(TrackSelector.selection(tracks: [audio(1, "jpn")], preferences: english, remembered: nil).subtitle == nil)
    }

    @Test("Always and Off modes, and forced subtitles")
    func subtitleModes() {
        let tracks = [
            audio(1, "eng", selected: true), subtitle(1, "eng", "Forced", forced: true), subtitle(2, "eng", "SDH"), subtitle(3, "eng"),
        ]
        let always = preferences(audio: ["en"], mode: .always)
        #expect(TrackSelector.selection(tracks: tracks, preferences: always, remembered: nil).subtitle == .track(3))

        // Off and Automatic still show forced subtitles in the audio's language.
        #expect(TrackSelector.selection(tracks: tracks, preferences: preferences(audio: ["en"], mode: .off), remembered: nil).subtitle == .track(1))
        #expect(TrackSelector.selection(tracks: tracks, preferences: preferences(audio: ["en"]), remembered: nil).subtitle == .track(1))

        let noForced = [audio(1, "eng", selected: true), subtitle(1, "eng")]
        #expect(TrackSelector.selection(tracks: noForced, preferences: preferences(audio: ["en"], mode: .off), remembered: nil).subtitle == .off)

        // The subtitle language follows the picked audio, not the file's default track.
        let dubbed = [audio(1, "jpn", selected: true), audio(2, "eng"), subtitle(1, "eng")]
        #expect(TrackSelector.selection(tracks: dubbed, preferences: preferences(audio: ["en"]), remembered: nil) == TrackSelection(audio: 2, subtitle: .off))
    }

    @Test("A remembered subtitle choice, including Off, is restored")
    func rememberedSubtitles() {
        let tracks = [audio(1, "jpn", selected: true), subtitle(1, "spa"), subtitle(2, "eng")]
        let english = preferences(audio: ["en"])

        #expect(TrackSelector.selection(tracks: tracks, preferences: english, remembered: RememberedTracks(subtitle: .off)).subtitle == .off)
        let spanish = RememberedTracks(subtitle: .track(TrackDescriptor(language: "es")))
        #expect(TrackSelector.selection(tracks: tracks, preferences: english, remembered: spanish).subtitle == .track(1))
        // Remembered language missing here: decide as if nothing were remembered.
        let german = RememberedTracks(subtitle: .track(TrackDescriptor(language: "de")))
        #expect(TrackSelector.selection(tracks: tracks, preferences: english, remembered: german).subtitle == .track(2))
    }

    @Test("Remembered choices survive being stored")
    func codable() throws {
        let original = RememberedTracks(
            audio: TrackDescriptor(language: "eng", title: "Surround", codec: "eac3", channelCount: 6),
            subtitle: .track(TrackDescriptor(language: "spa"))
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(RememberedTracks.self, from: data) == original)
        let off = RememberedTracks(subtitle: .off)
        #expect(try JSONDecoder().decode(RememberedTracks.self, from: JSONEncoder().encode(off)) == off)
    }
}

/// An in-memory `PlayerMemory` for tests.
actor FakePlayerMemory: PlayerMemory {
    private(set) var tracks: [String: RememberedTracks] = [:]
    private(set) var volume: RememberedVolume?
    private(set) var positions: [String: Double] = [:]

    init(volume: RememberedVolume? = nil, positions: [String: Double] = [:]) {
        self.volume = volume
        self.positions = positions
    }

    func rememberedPosition(for key: String) async -> Double? {
        positions[key]
    }

    private(set) var points: [String: ResumePoint] = [:]
    private(set) var durations: [String: Double] = [:]

    func remember(_ point: ResumePoint, duration: Double?, for key: String) async {
        points[key] = point
        positions[key] = point.position
        durations[key] = duration
    }

    func rememberedTracks(forAnyOf keys: [String]) async -> RememberedTracks? {
        keys.lazy.compactMap { self.tracks[$0] }.first
    }

    func remember(_ tracks: RememberedTracks, for keys: [String]) async {
        for key in keys {
            self.tracks[key] = tracks
        }
    }

    func rememberedVolume() async -> RememberedVolume? {
        volume
    }

    func remember(_ volume: RememberedVolume) async {
        self.volume = volume
    }
}

@MainActor
@Suite("Automatic track selection through the engine", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct TrackSelectionEngineTests {
    private func makePlayer(
        audio: [String],
        subtitles: [String]? = nil,
        mode: TrackPreferences.SubtitleMode = .automatic,
        memory: FakePlayerMemory? = nil
    ) throws -> PlayerModel {
        try PlayerModel(
            configuration: PlayerConfiguration(
                userAgent: "PlayerKitTests/1.0",
                logSubsystem: "test.playerkit",
                videoOutput: .none,
                playsAudio: false,
                trackPreferences: TrackPreferences(audioLanguages: audio, subtitleLanguages: subtitles ?? audio, subtitleMode: mode)
            ),
            memory: memory
        )
    }

    private func eventually(within timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Choices are saved in the background; wait until the one being checked has arrived.
    private func waitForSave(in memory: FakePlayerMemory, key: String, where isSaved: (RememberedTracks) -> Bool) async {
        for _ in 0 ..< 200 {
            if let saved = await memory.tracks[key], isSaved(saved) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func open(_ url: URL, in player: PlayerModel, memoryKeys: [String]? = nil) async throws {
        try player.open(PlayableSource(url: url), memoryKeys: memoryKeys)
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
        await player.waitForTrackSelection()
    }

    @Test("Picks the preferred language by tag, and subtitles when the sound is foreign")
    func byLanguageTag() async throws {
        let german = try makePlayer(audio: ["de"])
        defer { german.shutdown() }
        try await open(TestMedia.multiTrack, in: german)
        #expect(await eventually { german.state.selectedTrack(of: .audio)?.title == "Deutsch" })
        // German is understood, and the file has no German subtitles: none shown.
        #expect(await eventually { german.state.selectedTrack(of: .subtitle) == nil })

        // Hindi is not in the file: the default (French) audio stays, with English subtitles.
        let hindi = try makePlayer(audio: ["hi"], subtitles: ["en"])
        defer { hindi.shutdown() }
        try await open(TestMedia.multiTrack, in: hindi)
        #expect(await eventually { hindi.state.selectedTrack(of: .audio)?.language == "fra" })
        #expect(await eventually { hindi.state.selectedTrack(of: .subtitle)?.language == "eng" })
    }

    @Test("Falls back to a track whose title names the language when it is untagged")
    func byTitle() async throws {
        let player = try makePlayer(audio: ["en"])
        defer { player.shutdown() }
        try await open(TestMedia.multiTrack, in: player)
        #expect(await eventually { player.state.selectedTrack(of: .audio)?.title == "English" })
        #expect(player.state.selectedTrack(of: .audio)?.language == nil)
        #expect(await eventually { player.state.selectedTrack(of: .subtitle) == nil })
    }

    @Test("A manual choice is remembered for the file and for other files in its folder")
    func remembersChoices() async throws {
        let memory = FakePlayerMemory()
        let first = try makePlayer(audio: ["en"], memory: memory)
        try await open(TestMedia.multiTrack, in: first)
        #expect(await eventually { first.state.selectedTrack(of: .audio)?.title == "English" })

        first.selectTrack(.audio, number: 3)
        first.selectTrack(.subtitle, number: 1)
        #expect(await eventually { first.state.selectedTrack(of: .audio)?.language == "jpn" })
        first.shutdown()

        let fileKey = "file:" + TestMedia.multiTrack.path
        let folderKey = "folder:" + TestMedia.directory.path
        await waitForSave(in: memory, key: folderKey) { $0.subtitle != nil }
        #expect(await memory.tracks[fileKey]?.audio?.language == "jpn")
        #expect(await memory.tracks[folderKey]?.subtitle == .track(TrackDescriptor(language: "spa", codec: "subrip")))

        // A new player, same preferences: the remembered tracks win over them.
        let second = try makePlayer(audio: ["en"], memory: memory)
        defer { second.shutdown() }
        try await open(TestMedia.multiTrack, in: second)
        #expect(await eventually { second.state.selectedTrack(of: .audio)?.language == "jpn" })
        #expect(await eventually { second.state.selectedTrack(of: .subtitle)?.language == "spa" })

        // Another file in the folder has no Japanese track: preferences decide, nothing breaks.
        try await open(TestMedia.sdr, in: second)
        #expect(await eventually { second.state.selectedTrack(of: .audio)?.language == "eng" })
    }

    @Test("Turning subtitles off is remembered too, under the keys the caller supplies")
    func remembersSubtitlesOff() async throws {
        let memory = FakePlayerMemory()
        let first = try makePlayer(audio: ["hi"], subtitles: ["en"], memory: memory)
        try await open(TestMedia.multiTrack, in: first, memoryKeys: ["episode:s1e1", "series:example"])
        #expect(await eventually { first.state.selectedTrack(of: .subtitle)?.language == "eng" })
        first.selectTrack(.subtitle, number: nil)
        #expect(await eventually { first.state.selectedTrack(of: .subtitle) == nil })
        first.shutdown()
        await waitForSave(in: memory, key: "series:example") { $0.subtitle == .off }
        #expect(await memory.tracks["series:example"]?.subtitle == .off)
        #expect(await memory.tracks["file:" + TestMedia.multiTrack.path] == nil)

        // The "next episode": a different episode key, the same series key.
        let second = try makePlayer(audio: ["hi"], subtitles: ["en"], memory: memory)
        defer { second.shutdown() }
        try await open(TestMedia.multiTrack, in: second, memoryKeys: ["episode:s1e2", "series:example"])
        #expect(await eventually { second.state.selectedTrack(of: .subtitle) == nil })
    }

    @Test("Volume and mute are restored and saved")
    func volume() async throws {
        let memory = FakePlayerMemory(volume: RememberedVolume(level: 35, isMuted: true))
        let player = try makePlayer(audio: ["en"], memory: memory)
        defer { player.shutdown() }
        try await open(TestMedia.sdr, in: player)
        #expect(player.state.volume == 35)
        #expect(player.state.isMuted)
        #expect(player.engineProperty("volume").flatMap(Double.init) == 35)

        player.setVolume(60)
        player.setVolume(62)
        await player.waitForVolumeSave()
        #expect(await memory.volume == RememberedVolume(level: 62, isMuted: false))
    }

    @Test("Languages are handed to the engine in both code forms")
    func engineLanguageList() {
        #expect(PlayerConfiguration.engineLanguageList(["en", "fra", "en-GB", "und"]) == "en,eng,fr,fra")
        let options = PlayerConfiguration(
            userAgent: "x",
            logSubsystem: "t",
            trackPreferences: TrackPreferences(audioLanguages: ["de"], subtitleLanguages: [])
        ).engineOptions
        #expect(options.contains { $0.name == "alang" && $0.value == "de,deu" })
    }

    @Test("Sources are remembered under their file and folder, or their address without the query")
    func memoryKeys() throws {
        #expect(try PlayableSource(userInput: "/Shows/Example/S01E02.mkv").memoryKeys == ["file:/Shows/Example/S01E02.mkv", "folder:/Shows/Example"])
        #expect(try PlayableSource(userInput: "https://cdn.example.com/v/film.mp4?token=abc#t=1").memoryKeys == ["url:https://cdn.example.com/v/film.mp4"])
    }
}
