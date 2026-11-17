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
    public let player: PlayerCoordinator

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

    /// Seconds from process start to each launch milestone, once reached.
    public private(set) var launchDurations: [LaunchMetrics.Milestone: TimeInterval] = [:]

    @ObservationIgnored private let reportMilestone: @MainActor (LaunchMetrics.Milestone) -> TimeInterval?
    @ObservationIgnored private var reportedMilestones: Set<LaunchMetrics.Milestone> = []
    @ObservationIgnored private var hasStarted = false

    public init(
        dependencies: AppDependencies,
        initialSection: AppSection = .home,
        reportMilestone: (@MainActor (LaunchMetrics.Milestone) -> TimeInterval?)? = nil
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
        player = PlayerCoordinator(
            configuration: dependencies.playerConfiguration,
            memory: LibraryPlayerMemory(store: dependencies.playbackMemory, settings: dependencies.settings)
        )
        selection = initialSection
        currentSection = initialSection
        let subsystem = dependencies.branding.bundleIdentifier
        self.reportMilestone = reportMilestone ?? { LaunchMetrics.report($0, subsystem: subsystem) }
        home.onFirstContent = { [weak self] in
            self?.reached(.homeContent)
        }
    }

    public var branding: AppBranding {
        dependencies.branding
    }

    /// Loads the installed add-ons and starts feeding them to the screens.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        observeAddons()
        if let stored = try? await dependencies.settings.value(for: LibraryPlayerMemory.trackPreferencesKey) {
            player.configuration.trackPreferences = stored
        }
        await registry.start()
        await dependencies.imagePipeline.trimDiskCache()
    }

    /// Called when the root view first appears.
    public func firstScreenDidAppear() {
        reached(.firstScreen)
    }

    /// Records a launch milestone the first time it is reached; later calls do nothing.
    private func reached(_ milestone: LaunchMetrics.Milestone) {
        guard reportedMilestones.insert(milestone).inserted else { return }
        launchDurations[milestone] = reportMilestone(milestone)
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
