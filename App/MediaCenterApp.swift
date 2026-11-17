import AppUI
import SwiftUI

/// App entry point and composition root: builds the dependency graph and hands
/// it to the UI package. No feature logic lives in this target.
@main
struct MediaCenterApp: App {
    @State private var model = AppModel(branding: Branding.current)

    var body: some Scene {
        Window(Branding.current.name, id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 1200, height: 760)

        Settings {
            SettingsView()
        }
    }
}
