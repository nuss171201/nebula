import AppUI
import PlayerKit
import SwiftUI

/// App entry point and composition root: builds the dependency graph and hands
/// it to the UI package. No feature logic lives in this target.
@main
struct MediaCenterApp: App {
    @State private var model = MediaCenterApp.makeModel()

    var body: some Scene {
        Window(Branding.current.name, id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            PlaybackCommands(model: model)
        }

        Settings {
            SettingsView()
        }
    }

    private static func makeModel() -> AppModel {
        var playsAudio = true
        var engineOptions: [PlayerConfiguration.EngineOption] = []
        #if DEBUG
            playsAudio = !DebugLaunchOptions.isSilent
            engineOptions = DebugLaunchOptions.engineOptions
        #endif
        let model = AppModel(
            dependencies: .live(
                branding: Branding.current,
                defaultAddonAddresses: DefaultAddons.addresses(in: .main),
                playsAudio: playsAudio,
                additionalEngineOptions: engineOptions
            )
        )
        #if DEBUG
            DebugLaunchOptions.apply(to: model)
        #endif
        return model
    }
}
