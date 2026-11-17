import Foundation
import MediaCore

/// The one Swift access point for the app's identity.
///
/// To rename the app, edit `Config/Branding.xcconfig` (name and bundle identifier).
/// To change the icon, replace `App/Assets.xcassets/AppIcon.appiconset`
/// (regenerate the placeholder with `Scripts/generate-icon.swift`).
/// No other file hard-codes the name: packages receive this value by injection.
enum Branding {
    static let current = AppBranding(bundle: .main)
}
