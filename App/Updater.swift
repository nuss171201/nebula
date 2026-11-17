import AppUI
import Sparkle
import SwiftUI

/// The app's updater, if it has one.
///
/// There is one only when `Config/Branding.xcconfig` names an https feed and the public key
/// its updates are signed with (`UpdateConfiguration`), and never in a Debug build: a check
/// of the app must not go looking for updates. Without it there is no "Check for Updates…".
@MainActor
final class AppUpdater {
    let controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main) {
        #if DEBUG
            controller = nil
        #else
            if UpdateConfiguration(infoDictionary: bundle.infoDictionary) != nil {
                // Sparkle reads the same two Info.plist keys. It asks the user, on the second
                // launch, whether to check by itself; nothing is fetched before that answer.
                controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            } else {
                controller = nil
            }
        #endif
    }
}

/// "Check for Updates…" in the app menu, when there is an updater.
struct UpdaterCommands: Commands {
    let updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if let controller = updater.controller {
                Button("Check for Updates…") {
                    controller.checkForUpdates(nil)
                }
            }
        }
    }
}
