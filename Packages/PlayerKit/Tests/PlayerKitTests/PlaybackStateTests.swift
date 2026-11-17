import CoreGraphics
import Foundation
@testable import PlayerKit
import Testing

@Suite("Playback state")
struct PlaybackStateTests {
    private func state(after events: PlayerEvent...) -> PlaybackState {
        var state = PlaybackState()
        for event in events {
            state.apply(event)
        }
        return state
    }

    @Test("Opening a file goes idle → loading → playing, and the first frame is noted")
    func openingSequence() {
        var state = PlaybackState()
        #expect(state.phase == .idle)
        #expect(!state.hasMedia)

        state.apply(.startedLoading)
        #expect(state.phase == .loading)
        #expect(state.isBusy)

        state.apply(.fileLoaded)
        #expect(state.phase == .playing)
        #expect(state.hasMedia)
        #expect(!state.hasShownFirstFrame)

        state.apply(.playbackRestarted)
        #expect(state.hasShownFirstFrame)
        #expect(state.isAdvancing)
    }

    @Test("Properties update their fields, with values kept in range")
    func properties() {
        let state = state(
            after: .startedLoading, .fileLoaded,
            .property(.duration(120)), .property(.position(30)), .property(.paused(true)),
            .property(.volume(140)), .property(.muted(true)), .property(.title("Sample")),
            .property(.hardwareDecoder("videotoolbox")), .property(.bufferedAhead(12.5)),
            .property(.displayWidth(1920)), .property(.displayHeight(1080))
        )
        #expect(state.duration == 120)
        #expect(state.position == 30)
        #expect(state.progress == 0.25)
        #expect(state.isPaused)
        #expect(!state.isAdvancing)
        #expect(state.volume == 100)
        #expect(state.isMuted)
        #expect(state.title == "Sample")
        #expect(state.hardwareDecoder == "videotoolbox")
        #expect(state.bufferedAhead == 12.5)
        #expect(state.videoSize == CGSize(width: 1920, height: 1080))
    }

    @Test("Unavailable values read as unknown, not as zero-length media")
    func unavailableValues() {
        let state = state(
            after: .startedLoading, .fileLoaded,
            .property(.duration(nil)), .property(.position(nil)), .property(.displayWidth(1920))
        )
        #expect(state.duration == nil)
        #expect(state.progress == nil)
        #expect(state.position == 0)
        #expect(state.videoSize == nil)

        #expect(self.state(after: .property(.duration(0))).duration == nil)
        #expect(self.state(after: .property(.position(-3))).position == 0)
    }

    @Test("Stalling on the network shows as busy only while the user wants playback")
    func buffering() {
        var state = state(after: .startedLoading, .fileLoaded, .property(.waitingForData(true)))
        #expect(state.isBusy)
        #expect(!state.isAdvancing)
        state.apply(.property(.paused(true)))
        #expect(!state.isBusy)
    }

    @Test("Reaching the end is 'ended'; seeking back resumes")
    func endOfFile() {
        var state = state(after: .startedLoading, .fileLoaded, .property(.reachedEnd(true)))
        #expect(state.phase == .ended)
        #expect(state.hasMedia)
        state.apply(.property(.reachedEnd(false)))
        #expect(state.phase == .playing)

        #expect(self.state(after: .startedLoading, .fileLoaded, .ended(.reachedEnd)).phase == .ended)
        // The flag clearing while nothing is open must not invent a playing file.
        #expect(self.state(after: .property(.reachedEnd(false))).phase == .idle)
    }

    @Test("A failure keeps its message; stopping returns to idle")
    func failureAndStop() {
        #expect(state(after: .startedLoading, .ended(.failed("Could not open."))).phase == .failed("Could not open."))
        #expect(state(after: .startedLoading, .fileLoaded, .ended(.stopped)).phase == .idle)
        #expect(state(after: .startedLoading, .fileLoaded, .shutdown).phase == .idle)
    }

    @Test("Opening another file resets per-file values but keeps volume and mute")
    func replacingFile() {
        let state = state(
            after: .startedLoading, .fileLoaded, .playbackRestarted,
            .property(.duration(100)), .property(.position(50)), .property(.title("First")),
            .property(.volume(40)), .property(.muted(true)),
            // The engine reports the old file stopping after the new one starts loading.
            .startedLoading, .ended(.stopped)
        )
        #expect(state.phase == .loading)
        #expect(state.position == 0)
        #expect(state.duration == nil)
        #expect(state.title == nil)
        #expect(!state.hasShownFirstFrame)
        #expect(state.volume == 40)
        #expect(state.isMuted)
    }

    @Test("Times are shown as m:ss, or h:mm:ss from an hour up", arguments: [
        (0.0, "0:00"),
        (9.9, "0:09"),
        (75.0, "1:15"),
        (3599.0, "59:59"),
        (3600.0, "1:00:00"),
        (5025.4, "1:23:45"),
        (-4.0, "0:00"),
        (Double.nan, "0:00"),
        (Double.infinity, "0:00"),
    ])
    func timeFormatting(seconds: Double, expected: String) {
        #expect(PlaybackTime.format(seconds) == expected)
    }
}

@Suite("Engine values and configuration")
struct EngineMappingTests {
    @Test("Raw engine values are translated to player properties")
    func observedProperties() {
        #expect(ObservedProperty.pause.property(for: .flag(true)) == .paused(true))
        #expect(ObservedProperty.timePosition.property(for: .double(4.5)) == .position(4.5))
        #expect(ObservedProperty.timePosition.property(for: nil) == .position(nil))
        #expect(ObservedProperty.duration.property(for: nil) == .duration(nil))
        #expect(ObservedProperty.displayWidth.property(for: .int(3840)) == .displayWidth(3840))
        #expect(ObservedProperty.mediaTitle.property(for: .string("")) == .title(nil))
        #expect(ObservedProperty.hardwareDecoder.property(for: .string("videotoolbox")) == .hardwareDecoder("videotoolbox"))
        #expect(ObservedProperty.hardwareDecoder.property(for: .string("no")) == .hardwareDecoder(nil))
        #expect(ObservedProperty.endOfFileReached.property(for: nil) == .reachedEnd(false))
        // A value of the wrong type is ignored rather than misread.
        #expect(ObservedProperty.pause.property(for: .double(1)) == nil)
        #expect(ObservedProperty.volume.property(for: nil) == nil)
    }

    @Test("Every observed property has a distinct id and name")
    func observedPropertyTable() {
        let all = ObservedProperty.allCases
        #expect(Set(all.map(\.rawValue)).count == all.count)
        #expect(Set(all.map(\.name)).count == all.count)
        #expect(all.filter(\.isHighFrequency).map(\.name).sorted() == ["demuxer-cache-duration", "time-pos"])
    }

    @Test("The configuration becomes engine options, with the app in sole control")
    func engineOptions() {
        let options = PlayerConfiguration(userAgent: "Tests/1.0", logSubsystem: "test").engineOptions
        let table = Dictionary(options.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(table.count == options.count)
        #expect(table["vo"] == "gpu-next")
        #expect(table["gpu-context"] == "moltenvk")
        #expect(table["hwdec"] == "videotoolbox")
        #expect(table["user-agent"] == "Tests/1.0")
        #expect(table["config"] == "no")
        #expect(table["input-default-bindings"] == "no")
        #expect(table["load-scripts"] == "no")
        #expect(table["ytdl"] == "no")
        #expect(table["keep-open"] == "yes")
        #expect(table["ao"] == nil)
        #expect(table["volume"] == "100.0")
        // The stream cache is kept small enough for 4K to stay inside the memory target,
        // and an options file can still say otherwise (its options come later).
        #expect(table["demuxer-max-bytes"] == "48MiB")
        #expect(table["demuxer-max-back-bytes"] == "8MiB")
        #expect(table["demuxer-donate-buffer"] == "no")
        var tuned = PlayerConfiguration(userAgent: "x", logSubsystem: "test")
        tuned.additionalEngineOptions = [.init("demuxer-max-bytes", "200MiB")]
        #expect(tuned.engineOptions.last { $0.name == "demuxer-max-bytes" }?.value == "200MiB")
        // The efficient renderer is the default; the high-quality one adds no overrides.
        #expect(table["profile"] == "fast")
        #expect(table["dither"] == "ordered")
        let high = PlayerConfiguration(userAgent: "x", logSubsystem: "test", renderQuality: .high).engineOptions
        #expect(!high.contains { $0.name == "profile" || $0.name == "dither" })

        let quiet = PlayerConfiguration(
            userAgent: "x",
            logSubsystem: "test",
            videoOutput: .none,
            usesHardwareDecoding: false,
            playsAudio: false
        ).engineOptions
        let quietTable = Dictionary(quiet.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        #expect(quietTable["vo"] == "null")
        #expect(quietTable["gpu-api"] == nil)
        #expect(quietTable["hwdec"] == "no")
        #expect(quietTable["ao"] == "null")
        #expect(quietTable["profile"] == nil)

        // Extra options come last, so they can override anything above.
        let extra = PlayerConfiguration(
            userAgent: "x",
            logSubsystem: "test",
            additionalEngineOptions: PlayerConfiguration.EngineOption.parse("hwdec=no, deband ,=bad,scale=bilinear")
        ).engineOptions
        #expect(extra.suffix(3).map(\.name) == ["hwdec", "deband", "scale"])
        #expect(extra.suffix(3).map(\.value) == ["no", "yes", "bilinear"])
        #expect(PlayerConfiguration.EngineOption.parse("").isEmpty)
    }

    @Test("Only local files and http(s) addresses can be opened", arguments: [
        ("/Users/someone/Movies/film.mkv", "/Users/someone/Movies/film.mkv"),
        ("  /tmp/a b.mp4 ", "/tmp/a b.mp4"),
        ("file:///tmp/clip.mp4", "/tmp/clip.mp4"),
        ("https://example.com/video.mp4?token=1", "https://example.com/video.mp4?token=1"),
        ("http://127.0.0.1:8080/stream", "http://127.0.0.1:8080/stream"),
    ])
    func acceptedSources(input: String, engineArgument: String) throws {
        #expect(try PlayableSource(userInput: input).engineArgument == engineArgument)
    }

    @Test("Other schemes and incomplete addresses are refused", arguments: [
        ("", PlayableSource.Rejection.empty),
        ("   ", .empty),
        ("relative/path.mp4", .notAbsolute),
        ("example.com/video.mp4", .notAbsolute),
        ("https:///no-host.mp4", .notAbsolute),
        ("edl://something", .unsupportedScheme("edl")),
        ("av://lavfi:testsrc", .unsupportedScheme("av")),
        ("lavfi://testsrc", .unsupportedScheme("lavfi")),
        ("smb://server/share/file.mkv", .unsupportedScheme("smb")),
        ("javascript:alert(1)", .unsupportedScheme("javascript")),
    ])
    func rejectedSources(input: String, expected: PlayableSource.Rejection) {
        #expect(throws: expected) {
            try PlayableSource(userInput: input)
        }
    }

    @Test("A source has a readable name before the media reports its title")
    func displayNames() throws {
        #expect(try PlayableSource(userInput: "/tmp/My Film.mkv").displayName == "My Film.mkv")
        #expect(try PlayableSource(userInput: "https://example.com/path/clip.mp4").displayName == "clip.mp4")
        #expect(try PlayableSource(userInput: "https://example.com").displayName == "example.com")
        #expect(try PlayableSource(userInput: "~/x.mp4").isLocalFile)
    }

    @Test("Default key bindings cover the basic controls without clashes")
    func keyBindings() {
        let bindings = KeyBindings.standard
        #expect(bindings.command(for: KeyChord(.space)) == .togglePause)
        #expect(bindings.command(for: KeyChord(.leftArrow)) == .seekBy(-5))
        #expect(bindings.command(for: KeyChord(.rightArrow, .shift)) == .seekBy(30))
        #expect(bindings.command(for: KeyChord(.upArrow)) == .changeVolumeBy(5))
        #expect(bindings.command(for: KeyChord(.character("m"))) == .toggleMute)
        #expect(bindings.command(for: KeyChord(.character("f"))) == .toggleFullScreen)
        #expect(bindings.command(for: KeyChord(.escape)) == .exitFullScreen)
        #expect(bindings.command(for: KeyChord(.space, .command)) == nil)
        #expect(bindings.command(for: KeyChord(.character("q"))) == nil)
        #expect(bindings.command(for: KeyChord(.character("s"), .command)) == .screenshot(includingSubtitles: true))
        #expect(bindings.command(for: KeyChord(.character("."))) == .stepFrameForward)
    }
}
