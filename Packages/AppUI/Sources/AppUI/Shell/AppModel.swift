import Foundation
import MediaCore
import Observation

/// Root view model: owns navigation state and the per-screen view models, and
/// keeps them in step with the installed add-ons.
@MainActor
@Observable
public final class AppModel {
    public let dependencies: AppDependencies
    public let registry: AddonRegistry
    public let home: HomeModel
    public let discover: DiscoverModel
    public let search: SearchModel
    public let addons: AddonsModel

    /// The sidebar selection. Optional because a list selection can be cleared;
    /// `currentSection` is what the detail area should show.
    public var selection: AppSection? {
        didSet {
            if let selection, selection != currentSection {
                currentSection = selection
                path = []
            }
        }
    }

    /// The section to display. Keeps the last one if the selection is cleared.
    public private(set) var currentSection: AppSection

    /// Detail pages pushed on top of the current section.
    public var path: [MediaRoute] = []

    /// Seconds from process start to the first screen, once measured.
    public private(set) var launchDuration: TimeInterval?

    @ObservationIgnored private let reportLaunch: @MainActor () -> TimeInterval?
    @ObservationIgnored private var hasStarted = false

    public init(
        dependencies: AppDependencies,
        initialSection: AppSection = .home,
        reportLaunch: (@MainActor () -> TimeInterval?)? = nil
    ) {
        self.dependencies = dependencies
        let client = dependencies.addonClient
        registry = AddonRegistry(
            client: client,
            store: dependencies.addonStore,
            settings: dependencies.settings,
            defaultAddresses: dependencies.defaultAddonAddresses
        )
        home = HomeModel(client: client)
        discover = DiscoverModel(client: client)
        search = SearchModel(client: client)
        addons = AddonsModel(registry: registry)
        selection = initialSection
        currentSection = initialSection
        let subsystem = dependencies.branding.bundleIdentifier
        self.reportLaunch = reportLaunch ?? { LaunchMetrics.reportFirstScreen(subsystem: subsystem) }
    }

    public var branding: AppBranding {
        dependencies.branding
    }

    /// Loads the installed add-ons and starts feeding them to the screens.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        observeAddons()
        await registry.start()
        await dependencies.imagePipeline.trimDiskCache()
    }

    /// Called when the root view first appears. Records the launch time exactly once.
    public func firstScreenDidAppear() {
        guard launchDuration == nil else { return }
        launchDuration = reportLaunch()
    }

    public func detailModel(for route: MediaRoute) -> DetailModel {
        DetailModel(route: route, client: dependencies.addonClient)
    }

    /// Pushes the installed add-ons to every screen now and again whenever they change.
    private func observeAddons() {
        let addons = withObservationTracking {
            registry.addons
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeAddons()
            }
        }
        home.update(addons: addons)
        discover.update(addons: addons)
        search.update(addons: addons)
    }
}
