@testable import AppUI
import Foundation
import PlayerKit
import Testing

/// A sample written by `Scripts/make-test-media.sh`.
private let sampleFile = URL(filePath: #filePath)
    .deletingLastPathComponent() // AppUITests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // AppUI
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // repository root
    .appending(path: "TestMedia/sdr-h264-1080p.mp4")

@MainActor
@Suite("Opening media in the player")
struct PlayerCoordinatorTests {
    private func makeCoordinator() -> PlayerCoordinator {
        PlayerCoordinator(
            configuration: PlayerConfiguration(userAgent: "AppUITests/1.0", logSubsystem: "test.appui", playsAudio: false),
            presentsWindow: false
        )
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 500 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("Input that cannot be played is refused with a message and opens nothing", arguments: [
        ("", "Enter a file path or a web address."),
        ("not a path", "That is not a complete file path or web address."),
        ("ftp://example.com/file.mkv", "“ftp” addresses cannot be played. Use a file or an http(s) address."),
    ])
    func rejectsInput(input: String, message: String) {
        let coordinator = makeCoordinator()
        #expect(!coordinator.play(userInput: input))
        #expect(coordinator.errorMessage == message)
        #expect(!coordinator.isPlayerOpen)
        #expect(coordinator.player == nil)
    }

    @Test(
        "A file opens the player; opening another reuses it; closing releases it",
        .enabled(if: FileManager.default.fileExists(atPath: sampleFile.path), "run Scripts/make-test-media.sh first")
    )
    func playsReusesAndCloses() async throws {
        let coordinator = makeCoordinator()
        coordinator.errorMessage = "stale"

        #expect(coordinator.play(userInput: sampleFile.path))
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.isPlayerOpen)
        let player = try #require(coordinator.player)
        #expect(await eventually { player.state.phase == .playing })

        #expect(coordinator.play(fileURL: sampleFile))
        #expect(coordinator.player === player)

        coordinator.closePlayer()
        #expect(!coordinator.isPlayerOpen)
        #expect(coordinator.player == nil)
    }

    @Test(
        "Several files and folders open as a queue; subtitle files join the open video; anything else is refused in words",
        .enabled(if: FileManager.default.fileExists(atPath: sampleFile.path), "run Scripts/make-test-media.sh first")
    )
    func opensSelections() async throws {
        let media = sampleFile.deletingLastPathComponent()
        let coordinator = makeCoordinator()

        // A subtitle file with nothing to add it to, and a file that is not media.
        #expect(await coordinator.open(urls: [media.appending(path: "external-subs.en.srt")]) == false)
        #expect(coordinator.errorMessage == "Open a video first, then add subtitles to it.")
        #expect(await coordinator.open(urls: [URL(filePath: #filePath)]) == false)
        #expect(coordinator.errorMessage == "There was nothing there that can be played.")
        #expect(!coordinator.isPlayerOpen)

        // Two files: a queue of two, the first playing.
        #expect(await coordinator.open(urls: [sampleFile, media.appending(path: "multi-track.mkv")]))
        #expect(coordinator.errorMessage == nil)
        let player = try #require(coordinator.player)
        #expect(await eventually { player.state.playlist.count == 2 && player.state.phase == .playing })
        #expect(player.state.playlist.map(\.displayName) == ["sdr-h264-1080p.mp4", "multi-track.mkv"])
        #expect(await eventually { player.state.playlist.first?.isCurrent == true })

        // A subtitle file now joins what is playing.
        #expect(await eventually { player.state.hasShownFirstFrame })
        #expect(await coordinator.open(urls: [media.appending(path: "external-subs.en.srt")]))
        #expect(await eventually { player.state.selectedTrack(of: .subtitle)?.isExternal == true })
        #expect(player.state.playlist.count == 2)

        // A folder: everything playable in it, in name order.
        #expect(await coordinator.open(urls: [media]))
        #expect(await eventually { player.state.playlist.count >= 4 })
        let names = player.state.playlist.map(\.displayName)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        #expect(!names.contains("external-subs.en.srt"))
        coordinator.closePlayer()
    }

    @Test("The Open panel offers video and audio, including containers the system has no type for")
    func playableTypes() {
        let extensions = Set(PlayerCoordinator.playableTypes.compactMap(\.preferredFilenameExtension))
        #expect(extensions.contains("mkv"))
        #expect(extensions.contains("webm"))
        #expect(PlayerCoordinator.playableTypes.contains(.movie))
        #expect(PlayerCoordinator.playableTypes.contains(.audio))
    }
}
