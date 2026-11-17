import AppUI
import MediaCore
import PlayerKit
import SwiftUI

/// App entry point and composition root: builds the dependency graph and hands
/// it to the UI package. No feature logic lives in this target.
@main
struct MediaCenterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = MediaCenterApp.makeModel()

    var body: some Scene {
        Window(Branding.current.name, id: "main") {
            RootView(model: model)
                .onAppear {
                    delegate.onOpen = { [model] urls in
                        Task { await model.player.open(urls: urls) }
                    }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            PlaybackCommands(model: model)
        }

        Settings {
            SettingsView(model: model.settings)
        }
    }

    private static func makeModel() -> AppModel {
        ProcessLimits.raiseOpenFileLimit()
        var playsAudio = true
        var engineOptions: [PlayerConfiguration.EngineOption] = []
        var profile: URL?
        #if DEBUG
            playsAudio = !DebugLaunchOptions.isSilent
            engineOptions = DebugLaunchOptions.engineOptions
            profile = DebugLaunchOptions.profileDirectory
        #endif
        let model = AppModel(
            dependencies: .live(
                branding: Branding.current,
                defaultAddonAddresses: DefaultAddons.addresses(in: .main),
                playsAudio: playsAudio,
                additionalEngineOptions: engineOptions,
                profileDirectory: profile,
                // A check with a scratch profile streams only between programs on this machine.
                streamsStayLocal: profile != nil
            )
        )
        #if DEBUG
            DebugLaunchOptions.apply(to: model)
        #endif
        return model
    }
}

/// Receives files and folders sent to the app from Finder: "Open With", a double-click on a
/// file the app is the default for, or a drop on its Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the main window exists. What arrived before that is delivered then.
    var onOpen: (([URL]) -> Void)? {
        didSet {
            if let onOpen, !waiting.isEmpty {
                onOpen(waiting)
                waiting = []
            }
        }
    }

    private var waiting: [URL] = []

    func application(_: NSApplication, open urls: [URL]) {
        if let onOpen {
            onOpen(urls)
        } else {
            waiting += urls
        }
    }
}
