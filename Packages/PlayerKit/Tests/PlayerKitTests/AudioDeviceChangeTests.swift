import CoreAudio
import Foundation
@testable import PlayerKit
import Testing

/// Opt-in, because it changes the system's list of audio devices for a second (it adds an
/// empty device and removes it, as headphones coming and going would; nothing is played
/// through it and nothing is selected):
///
///     AUDIO_DEVICE_TESTS=1 MallocScribble=1 swift test --filter AudioDeviceChangeTests
///
/// `MallocScribble` overwrites freed memory, which turns "works by luck" into a crash. With the
/// engine left to choose its audio output, this test crashes the test process in `hotplug_cb`
/// (as the app did); `AUDIO_DEVICE_OUTPUT=coreaudio,avfoundation` shows it. A crash here is a
/// crash of the whole test run, which is the other reason it is not run by default.
@MainActor
@Suite("Audio devices coming and going", .enabled(if: ProcessInfo.processInfo.environment["AUDIO_DEVICE_TESTS"] == "1"))
struct AudioDeviceChangeTests {
    @Test("The app outlives a change to the audio devices after a film has played and its player has closed")
    func survivesADeviceChange() async throws {
        var configuration = PlayerConfiguration(
            userAgent: "PlayerKitTests/1.0", logSubsystem: "test.playerkit", videoOutput: .none, playsAudio: true, initialVolume: 0
        )
        if let output = ProcessInfo.processInfo.environment["AUDIO_DEVICE_OUTPUT"] {
            // To see the fault: the engine's own order of outputs, as it was before.
            configuration.audioOutput = output
        }
        let player = try PlayerModel(configuration: configuration)
        try player.open(PlayableSource(url: TestMedia.multiTrack))
        try await Task.sleep(for: .seconds(2))
        if configuration.audioOutput == "avfoundation" {
            #expect(player.engineProperty("current-ao") == "avfoundation")
        }
        player.shutdown()
        try await Task.sleep(for: .seconds(1))

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Player check (temporary)",
            kAudioAggregateDeviceUIDKey: "player.check.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 0,
        ]
        var device = AudioObjectID(0)
        try #require(AudioHardwareCreateAggregateDevice(description as CFDictionary, &device) == noErr)
        try await Task.sleep(for: .seconds(1))
        #expect(AudioHardwareDestroyAggregateDevice(device) == noErr)
        // The listeners are called on a queue of the system's; give them time to be.
        try await Task.sleep(for: .seconds(2))
    }
}
