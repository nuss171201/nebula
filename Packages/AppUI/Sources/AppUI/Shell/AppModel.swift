import Foundation
import MediaCore
import Observation

/// Root view model: owns navigation state and the app-wide dependencies that
/// screens are built from. Created once by the app target's composition root.
@MainActor
@Observable
public final class AppModel {
    public let branding: AppBranding

    /// The sidebar selection. Optional because a list selection can be cleared;
    /// `currentSection` is what the detail area should show.
    public var selection: AppSection? {
        didSet {
            if let selection {
                currentSection = selection
            }
        }
    }

    /// The section to display. Keeps the last one if the selection is cleared.
    public private(set) var currentSection: AppSection

    /// Seconds from process start to the first screen, once measured.
    public private(set) var launchDuration: TimeInterval?

    @ObservationIgnored private let reportLaunch: @MainActor () -> TimeInterval?

    public init(
        branding: AppBranding,
        initialSection: AppSection = .home,
        reportLaunch: (@MainActor () -> TimeInterval?)? = nil
    ) {
        self.branding = branding
        selection = initialSection
        currentSection = initialSection
        let subsystem = branding.bundleIdentifier
        self.reportLaunch = reportLaunch ?? { LaunchMetrics.reportFirstScreen(subsystem: subsystem) }
    }

    /// Called when the root view first appears. Records the launch time exactly once.
    public func firstScreenDidAppear() {
        guard launchDuration == nil else { return }
        launchDuration = reportLaunch()
    }
}
