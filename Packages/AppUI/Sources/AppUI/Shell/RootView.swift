import AppKit
import MediaCore
import SwiftUI

/// The main window: a sidebar of sections and the selected section's screen,
/// with a search field that takes over the content while a query is entered.
public struct RootView: View {
    @Bindable private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        @Bindable var search = model.search
        @Bindable var player = model.player
        @Bindable var streamPlayer = model.streamPlayer

        NavigationSplitView {
            List(AppSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            NavigationStack(path: $model.path) {
                content
                    .navigationTitle(model.search.isActive ? "Search" : model.currentSection.title)
                    .navigationDestination(for: MediaRoute.self) { route in
                        DetailScreen(route: route, appModel: model)
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let warning = model.dependencies.startupWarning {
                            Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                                .font(.callout)
                                .padding(8)
                                .frame(maxWidth: .infinity)
                                .background(.orange.opacity(0.25))
                        }
                    }
            }
        }
        .searchable(text: $search.query, placement: .toolbar, prompt: "Search")
        .sheet(isPresented: $player.isOpenLocationPresented) {
            OpenLocationView(coordinator: model.player)
        }
        .sheet(item: $streamPlayer.youTubeVideo) { video in
            TrailerView(video: video, title: "", appIdentifier: model.branding.bundleIdentifier)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StreamStatusBar(player: model.streamPlayer)
        }
        // Files and folders dropped anywhere on the window are played.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await model.player.open(urls: files) }
            return true
        }
        .alert("Cannot Play", isPresented: playbackErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.player.errorMessage ?? "")
        }
        .environment(\.imagePipeline, model.dependencies.imagePipeline)
        .environment(\.openTitle, OpenTitleAction(owner: model) { [model] in model.path.append(MediaRoute(item: $0)) })
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            model.firstScreenDidAppear()
        }
        // For every window of the app, the Settings window included. The player stays dark.
        .onChange(of: model.settings.settings.appearance, initial: true) { _, appearance in
            // Only on a real change: assigning it redraws every window.
            if NSApplication.shared.appearance?.name != appearance.systemAppearance?.name {
                NSApplication.shared.appearance = appearance.systemAppearance
            }
        }
        .task {
            await model.start()
            if model.opensSettingsAtLaunch {
                openSettings()
            }
        }
    }

    /// Problems opening something from Finder, a drop or the Open panel. The Open Location
    /// sheet shows its own.
    private var playbackErrorBinding: Binding<Bool> {
        Binding {
            model.player.errorMessage != nil && !model.player.isOpenLocationPresented
        } set: { isPresented in
            if !isPresented {
                model.player.errorMessage = nil
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.search.isActive {
            SearchView(model: model.search)
        } else {
            switch model.currentSection {
            case .home:
                HomeView(
                    model: model.home,
                    registry: model.registry,
                    continueWatching: model.continueWatching,
                    library: model.library,
                    showsContinueWatching: model.settings.settings.showsContinueWatching
                ) { model.open($0) }
            case .discover:
                DiscoverView(model: model.discover, registry: model.registry) { model.path.append(MediaRoute(item: $0)) }
            case .addons:
                AddonsView(model: model.addons)
            case .library:
                LibraryView(model: model.libraryScreen, library: model.library) { model.open($0) }
            case .calendar:
                CalendarView(model: model.calendar, library: model.library, registry: model.registry) { model.open($0) }
            }
        }
    }
}
