import SwiftUI

/// The main window: a sidebar of sections and the selected section's screen.
public struct RootView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            SectionPlaceholderView(section: model.currentSection)
                .navigationTitle(model.currentSection.title)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            model.firstScreenDidAppear()
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

#Preview("Main window") {
    RootView(model: AppModel(
        branding: .init(name: "Preview", bundleIdentifier: "preview", version: "0", build: "0"),
        reportLaunch: { nil }
    ))
}
