import Foundation
@testable import PlayerKit
import Testing

@Suite("Audio fallback (pure)")
struct AudioFallbackLogicTests {
    private let tracks = [
        MediaTrack(kind: .audio, number: 1, language: "fra", codec: "truehd"),
        MediaTrack(kind: .audio, number: 2, language: "fre", codec: "ac3"),
        MediaTrack(kind: .audio, number: 3, language: "eng", codec: "aac"),
        MediaTrack(kind: .audio, number: 4, language: "fra", codec: "aac", isExternal: true),
        MediaTrack(kind: .subtitle, number: 1, language: "fra"),
    ]

    @Test("Another track in the same language comes first, then converting, then any other track")
    func order() {
        // French TrueHD fails: the French AC-3 track is the same language under another tag.
        #expect(AudioFallbackState.nextStep(failed: tracks[0], tracks: tracks, failedTracks: [1], canConvert: true) == .switchTo(2))
        // That fails too: convert rather than change language.
        #expect(AudioFallbackState.nextStep(failed: tracks[1], tracks: tracks, failedTracks: [1, 2], canConvert: true) == .convert)
        // Nothing to convert with: the English track is better than silence.
        #expect(AudioFallbackState.nextStep(failed: tracks[1], tracks: tracks, failedTracks: [1, 2], canConvert: false) == .switchTo(3))
        // Everything inside the file has failed. Tracks added from outside are never switched to.
        #expect(AudioFallbackState.nextStep(failed: tracks[2], tracks: tracks, failedTracks: [1, 2, 3], canConvert: false) == .giveUp)
        #expect(AudioFallbackState.nextStep(failed: tracks[2], tracks: tracks, failedTracks: [1, 2, 3], canConvert: true) == .convert)
    }

    @Test("ffmpeg is asked for one audio track as AAC, and may only read files and http(s)")
    func arguments() {
        let arguments = AudioTranscoder.arguments(input: "/films/a b.mkv", audioIndex: 2, output: URL(fileURLWithPath: "/tmp/out.mka"))
        #expect(arguments.contains("-nostdin"))
        #expect(arguments.firstIndex(of: "-i").map { arguments[$0 + 1] } == "/films/a b.mkv")
        #expect(arguments.firstIndex(of: "-map").map { arguments[$0 + 1] } == "0:a:2")
        #expect(arguments.firstIndex(of: "-c:a").map { arguments[$0 + 1] } == "aac")
        #expect(arguments.firstIndex(of: "-protocol_whitelist").map { arguments[$0 + 1] } == "file,http,https,tcp,tls,crypto")
        // The whitelist only applies to inputs that come after it.
        #expect((arguments.firstIndex(of: "-protocol_whitelist") ?? 99) < (arguments.firstIndex(of: "-i") ?? 0))
        #expect(arguments.last == "/tmp/out.mka")
    }

    @Test("A helper in the app comes before an installed ffmpeg; with neither there is no transcoder")
    func locating() {
        #expect(AudioTranscoder.locate { _ in false } == nil)
        #expect(AudioTranscoder.locate { $0 == "/usr/local/bin/ffmpeg" }?.executable.path == "/usr/local/bin/ffmpeg")
        #expect(AudioTranscoder.locate { $0.hasSuffix("/bin/ffmpeg") }?.executable.path == "/opt/homebrew/bin/ffmpeg")
    }
}

@MainActor
@Suite("Audio fallback through the engine", .enabled(if: TestMedia.isAvailable, "run Scripts/make-test-media.sh first"), .serialized)
struct AudioFallbackEngineTests {
    /// A player whose engine has no AC-3 decoder and which prefers French, the sample's AC-3 track.
    /// The engine cannot be told to leave one decoder out, only which ones it may use: the
    /// list names the decoders for the sample's other tracks, and the final "-" forbids the rest.
    private func makePlayer(transcoder: AudioTranscoder?) throws -> PlayerModel {
        try PlayerModel(configuration: PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0",
            logSubsystem: "test.playerkit",
            videoOutput: .none,
            playsAudio: false,
            trackPreferences: TrackPreferences(audioLanguages: ["fr"], subtitleLanguages: [], subtitleMode: .off),
            audioTranscoder: transcoder,
            additionalEngineOptions: [.init("ad", "eac3,dca,aac,-")]
        ))
    }

    private func eventually(within timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("Without a transcoder, a track that cannot be decoded is replaced by one that can, and the user is told")
    func switchesTrack() async throws {
        let player = try makePlayer(transcoder: nil)
        defer { player.shutdown() }
        try player.open(PlayableSource(url: TestMedia.multiTrack))
        #expect(await eventually { player.audioProblem != nil })
        #expect(await eventually { player.state.selectedTrack(of: .audio) != nil })
        let playing = try #require(player.state.selectedTrack(of: .audio))
        #expect(playing.codec != "ac3" && !playing.isExternal)
        #expect(player.audioProblem == "AC-3 sound cannot be played on this Mac. Playing \(playing.displayName()) instead.")
        #expect(player.audioFallback.failedTracks == [1])
        // The picture carries on throughout.
        let position = player.state.position
        #expect(await eventually { player.state.position > position + 0.3 })

        // A file without the problem clears the message.
        try player.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { player.state.phase == .playing && player.state.hasShownFirstFrame })
        #expect(player.audioProblem == nil && player.audioFallback.failedTracks.isEmpty)
    }

    @Test(
        "With ffmpeg available, the track is converted and played in the same language",
        .enabled(if: AudioTranscoder.locate() != nil, "needs an installed ffmpeg")
    )
    func converts() async throws {
        let player = try makePlayer(transcoder: AudioTranscoder.locate())
        defer { player.shutdown() }
        try player.open(PlayableSource(url: TestMedia.multiTrack))
        #expect(await eventually { player.state.selectedTrack(of: .audio)?.isExternal == true })
        let playing = try #require(player.state.selectedTrack(of: .audio))
        #expect(playing.codec == "aac")
        #expect(LanguageMatcher.matches(playing.language, "fr"))
        #expect(playing.title?.hasSuffix("(converted from AC-3)") == true)
        #expect(player.audioProblem == "AC-3 sound cannot be played directly, so it was converted.")
        let converted = try #require(player.audioFallback.convertedFiles[1])
        #expect(FileManager.default.fileExists(atPath: converted.path))

        // The converted file belongs to this file only: it is removed when another one opens.
        try player.open(PlayableSource(url: TestMedia.sdr))
        #expect(await eventually { !FileManager.default.fileExists(atPath: converted.path) })
    }

    @Test("A transcoder that fails falls through to another track")
    func conversionFails() async throws {
        // `false` exits with an error whatever it is asked.
        let player = try makePlayer(transcoder: AudioTranscoder(executable: URL(fileURLWithPath: "/usr/bin/false")))
        defer { player.shutdown() }
        try player.open(PlayableSource(url: TestMedia.multiTrack))
        #expect(await eventually { player.state.selectedTrack(of: .audio) != nil && player.audioProblem?.contains("instead") == true })
        #expect(player.state.selectedTrack(of: .audio)?.isExternal == false)
        #expect(player.audioFallback.convertedFiles.isEmpty)
    }
}
