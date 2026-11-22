import Foundation
@testable import PlayerKit
import Testing

@Suite("mpv.conf")
struct EngineConfigFileTests {
    @Test("Options are read in their three forms, with comments, quotes and leading dashes handled")
    func options() {
        let result = EngineConfigFile.parse("""
        # a comment
        deband=yes
        --scale = "ewa_lanczossharp"   # trailing comment
        interpolation
        no-audio-display
        sub-font='My Font #1'
        video-sync=display-resample#not-a-comment

        """)
        #expect(result.options == [
            .init("deband", "yes"), .init("scale", "ewa_lanczossharp"), .init("interpolation", "yes"),
            .init("audio-display", "no"), .init("sub-font", "My Font #1"), .init("video-sync", "display-resample#not-a-comment"),
        ])
        #expect(result.ignored.isEmpty)
    }

    @Test("What the app controls, and anything that reaches beyond playback, is left out and said so")
    func leftOut() {
        let result = EngineConfigFile.parse("""
        vo=gpu
        fullscreen
        input-default-bindings=yes
        script=/tmp/evil.lua
        include=/etc/passwd
        log-file=/tmp/out.log
        vf=lavfi=[something]
        hwdec=auto
        not an option!
        [myprofile]
        deband=no
        """)
        #expect(result.options == [.init("hwdec", "auto")])
        #expect(result.ignored.map(\.number) == [1, 2, 3, 4, 5, 6, 7, 9, 10])
        #expect(result.ignored[0].reason == "The app controls this itself.")
        #expect(result.ignored[3].reason.hasPrefix("Options that read other files"))
        #expect(result.ignored[7].reason == "This is not an option.")
        #expect(result.ignored[8].reason.hasPrefix("Profiles are not supported"))
        // Nothing after a profile heading is read, without a line each.
        #expect(!result.options.contains { $0.name == "deband" })
        #expect(EngineConfigFile.parse("").options.isEmpty)
    }
}

@Suite("input.conf")
struct InputConfigFileTests {
    @Test("Key names are read as the engine writes them", arguments: [
        ("SPACE", KeyChord(.space)), ("LEFT", KeyChord(.leftArrow)), ("Shift+RIGHT", KeyChord(.rightArrow, .shift)),
        ("ctrl+s", KeyChord(.character("s"), .control)), ("Q", KeyChord(.character("q"), .shift)),
        ("Alt+Meta+x", KeyChord(.character("x"), [.option, .command])), ("[", KeyChord(.character("["))),
        ("Ctrl++", KeyChord(.character("+"), .control)), ("ENTER", KeyChord(.returnKey)), ("ESC", KeyChord(.escape)),
    ])
    func keys(name: String, expected: KeyChord) {
        #expect(InputConfigFile.chord(named: name) == expected)
    }

    @Test("Keys the player has no name for are refused", arguments: ["F5", "MBTN_LEFT", "WHEEL_UP", "Hyper+a", "TAB", ""])
    func unknownKeys(name: String) {
        #expect(InputConfigFile.chord(named: name) == nil)
    }

    @Test("Commands become the player's own; prefixes and sections are passed over")
    func commands() {
        let result = InputConfigFile.parse("""
        SPACE cycle pause
        RIGHT seek 10
        Shift+LEFT no-osd seek -60 exact
        9 add volume -2
        m cycle mute
        f cycle fullscreen
        . frame-step
        ] multiply speed 1.1
        [ add speed -0.25
        BS set speed 1.0
        j cycle sub
        v cycle sub-visibility
        z add sub-delay -0.1
        s screenshot
        S screenshot video
        > playlist-next
        l ab-loop
        {encode} q quit
        """)
        #expect(result.ignored.map(\.number) == [10])
        #expect(result.bindings[KeyChord(.space)] == .some(.togglePause))
        #expect(result.bindings[KeyChord(.rightArrow)] == .some(.seekBy(10)))
        #expect(result.bindings[KeyChord(.leftArrow, .shift)] == .some(.seekBy(-60)))
        #expect(result.bindings[KeyChord(.character("9"))] == .some(.changeVolumeBy(-2)))
        #expect(result.bindings[KeyChord(.character("]"))] == .some(.speedUp))
        #expect(result.bindings[KeyChord(.character("["))] == .some(.slowDown))
        #expect(result.bindings[KeyChord(.character("j"))] == .some(.cycleTrack(.subtitle)))
        #expect(result.bindings[KeyChord(.character("z"))] == .some(.shiftSubtitleDelay(-0.1)))
        #expect(result.bindings[KeyChord(.character("s"))] == .some(.screenshot(includingSubtitles: true)))
        #expect(result.bindings[KeyChord(.character("s"), .shift)] == .some(.screenshot(includingSubtitles: false)))
        #expect(result.bindings[KeyChord(.character("q"))] == .some(.closePlayer))

        // ">" is typed with Shift held, which is how the key press arrives.
        let bindings = KeyBindings.standard.applying(result.bindings)
        #expect(bindings.command(for: KeyChord(.character(">"), .shift)) == .playNext)
        #expect(bindings.command(for: KeyChord(.character("s"), .shift)) == .screenshot(includingSubtitles: false))
        #expect(bindings.command(for: KeyChord(.character("y"), .shift)) == nil)
    }

    @Test("A silent player stays silent whatever an options file asks for")
    func silenceWins() {
        var configuration = PlayerConfiguration(userAgent: "Tests/1.0", logSubsystem: "test", playsAudio: false)
        configuration.additionalEngineOptions = [PlayerConfiguration.EngineOption("ao", "coreaudio")]
        let audio = configuration.engineOptions.last { $0.name == "ao" }
        #expect(audio?.value == "null")
        #expect(configuration.engineOptions.last?.name == "ao")
    }

    @Test("The audio output is the app's choice: an options file cannot bring the engine's other outputs back")
    func audioOutputIsFixed() {
        let parsed = EngineConfigFile.parse("ao=coreaudio\naudio-fallback-to-null=yes\naudio-channels=stereo")
        #expect(parsed.options.map(\.name) == ["audio-channels"])
        #expect(parsed.ignored.map(\.reason) == ["The app controls this itself.", "The app controls this itself."])

        // Even an option that got through some other way (an experiment's launch argument) loses.
        var configuration = PlayerConfiguration(userAgent: "Tests/1.0", logSubsystem: "test")
        configuration.additionalEngineOptions = [PlayerConfiguration.EngineOption("ao", "coreaudio,")]
        #expect(configuration.engineOptions.last?.name == "ao")
        #expect(configuration.engineOptions.last?.value == "avfoundation")
    }

    @Test("Commands with no equivalent are listed, never passed on; `ignore` unbinds")
    func leftOut() {
        let result = InputConfigFile.parse("""
        r run "/bin/sh" "-c" "rm -rf ~"
        k script-binding stats/display-stats
        p seek 50 absolute-percent
        x ignore
        F1 cycle pause
        y
        """)
        #expect(result.ignored.map(\.number) == [1, 2, 3, 5, 6])
        #expect(result.ignored[0].reason == "The player has no equivalent of this command.")
        #expect(result.ignored[3].reason == "This key cannot be bound here.")
        #expect(result.bindings.count == 1)
        #expect(result.bindings[KeyChord(.character("x"))] == .some(nil))

        // On top of the standard bindings: x is unbound, everything else stays.
        let bindings = KeyBindings.standard.applying(result.bindings)
        #expect(bindings.command(for: KeyChord(.character("x"))) == nil)
        #expect(bindings.command(for: KeyChord(.space)) == .togglePause)
    }

    @Test("Every action in the shortcut editor can be stored, and chords read as menus show them")
    func actions() {
        for action in ShortcutAction.all {
            #expect(action.command.identifier != nil, "\(action.title) cannot be stored")
        }
        #expect(Set(ShortcutAction.all.map(\.id)).count == ShortcutAction.all.count)
        #expect(ShortcutAction.describing(.togglePause)?.title == "Play / Pause")
        #expect(ShortcutAction.describing(.seekBy(-60))?.title == "Back 60 Seconds")
        #expect(ShortcutAction.describing(.changeVolumeBy(2))?.title == "Volume Up by 2")
        #expect(ShortcutAction.describing(.closePlayer)?.group == "Other")
        #expect(ShortcutAction.describing(.seekTo(10)) == nil)
        #expect(KeyChord(.character("s"), [.command, .shift]).displayText == "⇧⌘S")
        #expect(KeyChord(.space).displayText == "Space")
        #expect(KeyChord(.leftArrow, .option).displayText == "⌥←")
    }
}
