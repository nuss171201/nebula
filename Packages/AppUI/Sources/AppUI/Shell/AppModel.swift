import Foundation
import MediaCore
import MediaLibrary
import Observation
import PlayerKit

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
    public let streamPlayer: StreamPlayer
    public let library: LibraryCenter
    public let continueWatching: ContinueWatchingModel
    public let libraryScreen: LibraryModel
    public let nextEpisode: NextEpisodeController
    public let calendar: CalendarModel

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
    /// The detail page opened most recently, while it is on screen.
    @ObservationIgnored private weak var latestDetail: DetailModel?
    /// Episodes to show the streams of when their series' page opens, by series id.
    @ObservationIgnored private var pendingEpisodes: [String: String] = [:]

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
        let library = LibraryCenter(
            library: dependencies.libraryStore,
            history: dependencies.watchHistory,
            logSubsystem: dependencies.branding.bundleIdentifier
        )
        self.library = library
        continueWatching = ContinueWatchingModel(library: library, client: client)
        libraryScreen = LibraryModel(library: library)
        calendar = CalendarModel(library: library, client: client)
        player = PlayerCoordinator(
            configuration: dependencies.playerConfiguration,
            memory: LibraryPlayerMemory(
                store: dependencies.playbackMemory,
                settings: dependencies.settings,
                history: dependencies.watchHistory,
                historyChanged: { [weak library] in await library?.noteChange() }
            ),
            subtitleService: dependencies.subtitleService,
            usesSystemNowPlaying: dependencies.usesSystemNowPlaying
        )
        streamPlayer = StreamPlayer(coordinator: player, manager: dependencies.streamManager, library: library)
        nextEpisode = NextEpisodeController(coordinator: player, streamPlayer: streamPlayer, client: client)
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
        if let overrides = try? await dependencies.settings.value(for: LibraryPlayerMemory.keyBindingOverridesKey) {
            player.keyBindings = KeyBindings.standard.applying(overrides: overrides)
        }
        await registry.start()
        await dependencies.imagePipeline.trimDiskCache()
        // What earlier sessions streamed is kept up to the cache's budget.
        await dependencies.streamManager.trimCache()
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
        let model = DetailModel(
            route: route,
            client: dependencies.addonClient,
            streamMemory: LibraryStreamChoiceMemory(store: dependencies.playbackMemory),
            library: library
        )
        // Arriving from Continue Watching: go straight to the episode in question.
        model.initialVideoID = pendingEpisodes.removeValue(forKey: route.id)
        latestDetail = model
        return model
    }

    /// Opens the page of a video from Continue Watching or the history, with its streams showing.
    public func open(_ video: WatchVideo) {
        if video.videoID != video.titleID {
            pendingEpisodes[video.titleID] = video.videoID
        }
        path.append(MediaRoute(type: video.type, id: video.titleID))
    }

    /// Plays one of the streams listed on the detail page that was opened last, as a click on
    /// it would. Returns whether there was such a stream. For checking the app without the pointer.
    @discardableResult
    public func playListedStream(at index: Int) -> Bool {
        guard let detail = latestDetail, let video = detail.streamVideo, detail.streams.choices.indices.contains(index) else { return false }
        let choice = detail.streams.choices[index]
        detail.streams.didChoose(choice)
        streamPlayer.play(choice, for: video)
        return true
    }

    /// Saves the title on the detail page that was opened last to the library, as its button
    /// would. For checking the app without the pointer.
    public func saveShownTitleToLibrary() async {
        guard let detail = latestDetail, !detail.isInLibrary else { return }
        await detail.toggleLibrary()
    }

    /// Marks an episode (or, with the title's own id, the film) on the detail page that was
    /// opened last as watched. For checking the app without the pointer.
    public func markShownVideoWatched(withID videoID: String) async {
        guard let detail = latestDetail else { return }
        await detail.setWatched(true, video: detail.meta?.videos.first { $0.id == videoID })
    }

    /// Shows the streams of an episode on the detail page that was opened last, as a click on it would.
    @discardableResult
    public func showStreamsOfEpisode(withID videoID: String) -> Bool {
        guard let detail = latestDetail, let video = detail.meta?.videos.first(where: { $0.id == videoID }) else { return false }
        if detail.selectedVideoID != videoID {
            detail.toggleStreams(for: video)
        }
        return true
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
        continueWatching.update(addons: addons)
        nextEpisode.update(addons: addons)
        calendar.update(addons: addons)
        discover.update(addons: addons)
        search.update(addons: addons)
        dependencies.subtitleService.update(addons: addons)
    }
}
