import SwiftUI

/// The window that names the third-party code in the app and shows its licences.
public struct AcknowledgementsView: View {
    @Bindable private var model: AcknowledgementsModel

    public init(model: AcknowledgementsModel) {
        self.model = model
    }

    public var body: some View {
        if let catalog = model.catalog {
            NavigationSplitView {
                List(selection: $model.selection) {
                    ForEach(catalog.groups) { group in
                        Section {
                            ForEach(group.components) { component in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(component.title)
                                    Text(component.license)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .tag(component.id)
                                .accessibilityElement(children: .combine)
                            }
                        } header: {
                            Text(group.title)
                        } footer: {
                            Text(group.note)
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            } detail: {
                detail(sourceNote: catalog.sourceNote)
            }
            .frame(minWidth: 760, minHeight: 480)
        } else {
            ContentUnavailableView(
                "Acknowledgements Unavailable",
                systemImage: "doc.text",
                description: Text("The list of third-party software is missing from this copy of the app.")
            )
            .frame(minWidth: 520, minHeight: 320)
        }
    }

    @ViewBuilder
    private func detail(sourceNote: String) -> some View {
        if let component = model.selectedComponent {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(component.title)
                            .font(.title2.weight(.semibold))
                        Text(component.license)
                            .foregroundStyle(.secondary)
                        if let url = component.url {
                            Link(url.absoluteString, destination: url)
                                .font(.callout)
                        }
                    }
                    ForEach(model.texts, id: \.file) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.file)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(entry.text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Divider()
                    Text(sourceNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(20)
            }
            // A new component starts at its top, not where the last one was left.
            .id(component.id)
        } else {
            Text("Choose a component to read its licence.")
                .foregroundStyle(.secondary)
        }
    }
}

/// "Acknowledgements" in the app menu, under About.
public struct AcknowledgementsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Acknowledgements") {
                openWindow(id: AcknowledgementsModel.windowID)
            }
        }
    }
}
