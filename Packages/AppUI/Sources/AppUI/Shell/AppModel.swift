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
    public let settings: SettingsModel
    public let downloads: DownloadCenter
    /// The Anime section's board: the catalogs of anime, with a banner of their own.
    public let anime: HomeModel

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
    @ObservationIgnored private let usesStartSection: Bool
    /// Opens the Settings window once the app has started. For checking it without the pointer.
    @ObservationIgnored public var opensSettingsAtLaunch = false
    /// Opens the Acknowledgements window once the app has started. For checking it without the pointer.
    @ObservationIgnored public var opensAcknowledgementsAtLaunch = false
    /// The detail page opened most recently, while it is on screen.
    @ObservationIgnored private weak var latestDetail: DetailModel?
    /// Episodes to show the streams of when their series' page opens, by series id.
    @ObservationIgnored private var pendingEpisodes: [String: String] = [:]
    /// Titles whose page is to start playing by itself, by id: opened by a Play button elsewhere.
    @ObservationIgnored private var pendingPlays: Set<String> = []

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
            defaults: dependencies.defaultAddons
        )
        // Anime has a section of its own, so Home leaves it out.
        home = HomeModel(client: client) { !$0.isAnime }
        anime = HomeModel(client: client) { $0.isAnime }
        downloads = DownloadCenter(dependencies: dependencies)
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
        streamPlayer = StreamPlayer(
            coordinator: player,
            manager: dependencies.streamManager,
            library: library,
            subtitleService: dependencies.subtitleService
        )
        nextEpisode = NextEpisodeController(coordinator: player, streamPlayer: streamPlayer, client: client)
        settings = SettingsModel(
            store: dependencies.settings,
            coordinator: player,
            streamManager: dependencies.streamManager,
            nextEpisode: nextEpisode,
            configFolder: dependencies.engineConfigFolder
        )
        streamPlayer.onSessionSpeed = { [settings] rate in
            settings.noteStreamSession(bestRate: rate)
        }
        selection = initialSection
        currentSection = initialSection
        usesStartSection = initialSection == .home
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
        // Side by side: the add-ons' catalogs are what the first screen waits for, and nothing
        // about fetching them depends on a setting.
        async let addonsLoaded: Void = registry.start()
        await settings.load()
        // The section to open on, unless something (a debug argument, the user) chose one already.
        if usesStartSection, currentSection == .home, path.isEmpty {
            selection = settings.settings.startSection
        }
        await addonsLoaded
        await dependencies.imagePipeline.trimDiskCache()
        // What earlier sessions streamed is kept up to the cache's budget.
        await dependencies.streamManager.trimCache()
        // Carries on with what was being downloaded when the app was last quit.
        await downloads.load()
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
        model.streams.sort = settings.settings.streamSort
        model.streams.presentation = settings.settings.streamListStyle
        model.streams.configure(settings.pickerContext)
        // Arriving from Continue Watching: go straight to the episode in question.
        model.initialVideoID = pendingEpisodes.removeValue(forKey: route.id)
        model.startsPlaying = pendingPlays.remove(route.id) != nil
        // Not noted as the page on screen here: SwiftUI calls this more often than it shows a
        // page (see `detailDidAppear`).
        return model
    }

    /// Opens the page of a video from Continue Watching or the history, with its streams showing.
    public func open(_ video: WatchVideo) {
        if video.videoID != video.titleID {
            pendingEpisodes[video.titleID] = video.videoID
        }
        path.append(MediaRoute(type: video.type, id: video.titleID))
    }

    /// Shows a title's page in place of the one that is showing (another season of the same
    /// series), so that Back leads to where the user came from and not through every season.
    public func showInstead(_ item: MetaItem) {
        let route = MediaRoute(item: item)
        if path.isEmpty {
            path.append(route)
        } else {
            path[path.count - 1] = route
        }
    }

    /// Opens a title's page and has it play: a film at once, a series from where it was left.
    /// With no add-on that offers streams, the page opens and says so.
    public func play(_ item: MetaItem) {
        pendingPlays.insert(item.id)
        path.append(MediaRoute(item: item))
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

    /// A title's page is on screen with this model. SwiftUI may build several models for one
    /// page and keep only the first, so the page says which one it kept; without this the
    /// helpers below sometimes held one that was never shown.
    public func detailDidAppear(_ detail: DetailModel) {
        latestDetail = detail
    }

    /// Plays what the picker thinks best of a page's streams, as its Play button does: the
    /// first that starts, of the three most suitable.
    ///
    /// A video that has been downloaded plays from its file: nothing to choose, nothing to wait for.
    public func playBestStream(of detail: DetailModel) {
        guard let video = detail.streamVideo else { return }
        if let file = downloads.finishedFile(for: video) {
            streamPlayer.playFile(file, for: video)
            return
        }
        streamPlayer.playAutomatically(detail.streams.picks.map(\.choice), for: video) { [weak detail] choice in
            detail?.streams.didChoose(choice)
        }
    }

    /// Plays a finished download. Returns whether its file was there to play.
    @discardableResult
    public func play(_ download: DownloadItem) -> Bool {
        guard let file = downloads.finishedFile(for: download.video) else { return false }
        streamPlayer.playFile(file, for: download.video)
        return true
    }

    /// Starts downloading what Play would play on the detail page that was opened last.
    /// Returns whether there was anything to download. For checking the app without the pointer.
    @discardableResult
    public func downloadBestStreamOfShownTitle() -> Bool {
        guard let detail = latestDetail, let video = detail.streamVideo,
              let choice = detail.streams.picks.map(\.choice).first(where: DownloadCenter.canDownload)
        else { return false }
        return downloads.add(choice, for: video) != nil
    }

    /// Presses Play on the detail page that was opened last. Returns whether there was
    /// anything to choose from. For checking the app without the pointer.
    @discardableResult
    public func pressPlayOnShownTitle() -> Bool {
        guard let detail = latestDetail, !detail.streams.picks.isEmpty else { return false }
        playBestStream(of: detail)
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
        anime.update(addons: addons)
        continueWatching.update(addons: addons)
        nextEpisode.update(addons: addons)
        calendar.update(addons: addons)
        discover.update(addons: addons)
        search.update(addons: addons)
        dependencies.subtitleService.update(addons: addons)
    }
}
