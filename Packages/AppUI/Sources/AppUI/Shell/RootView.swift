import MediaCore
import SwiftUI

/// The main window: a sidebar of sections and the selected section's screen,
/// with a search field that takes over the content while a query is entered.
public struct RootView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        @Bindable var search = model.search
        @Bindable var player = model.player

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
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            model.firstScreenDidAppear()
        }
        .task {
            await model.start()
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
                HomeView(model: model.home, registry: model.registry)
            case .discover:
                DiscoverView(model: model.discover, registry: model.registry)
            case .addons:
                AddonsView(model: model.addons)
            case .library, .calendar:
                SectionPlaceholderView(section: model.currentSection)
            }
        }
    }
}

/// Empty state for a section whose content has not been built yet.
struct SectionPlaceholderView: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView(
            section.title,
            systemImage: section.systemImage,
            description: Text(section.emptyStateMessage)
        )
    }
}

/// Content of the Settings window (⌘,).
public struct SettingsView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView(
            "Settings",
            systemImage: "gearshape",
            description: Text("Playback, streaming and interface options will appear here.")
        )
        .frame(width: 520, height: 320)
    }
}
