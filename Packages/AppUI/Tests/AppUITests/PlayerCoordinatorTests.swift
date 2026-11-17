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

    @Test("The Open panel offers video and audio, including containers the system has no type for")
    func playableTypes() {
        let extensions = Set(PlayerCoordinator.playableTypes.compactMap(\.preferredFilenameExtension))
        #expect(extensions.contains("mkv"))
        #expect(extensions.contains("webm"))
        #expect(PlayerCoordinator.playableTypes.contains(.movie))
        #expect(PlayerCoordinator.playableTypes.contains(.audio))
    }
}
