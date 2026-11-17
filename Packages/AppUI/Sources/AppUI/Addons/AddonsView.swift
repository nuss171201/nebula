import MediaCore
import SwiftUI

/// Manage installed add-ons and install new ones by address.
struct AddonsView: View {
    @Bindable var model: AddonsModel

    private var registry: AddonRegistry {
        model.registry
    }

    var body: some View {
        VStack(spacing: 0) {
            installBar
            Divider()
            if registry.addons.isEmpty {
                ContentUnavailableView(
                    "No Add-ons",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Paste an add-on's address above to install it.")
                )
            } else {
                List {
                    ForEach(registry.addons) { addon in
                        AddonRow(addon: addon, registry: registry)
                    }
                    .onMove { source, destination in
                        Task { await registry.move(fromOffsets: source, toOffset: destination) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $model.pendingInstall) { addon in
            AddonInstallSheet(addon: addon) {
                Task { await model.confirmInstall() }
            } cancel: {
                model.cancelInstall()
            }
        }
    }

    private var installBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Paste an add-on address to install it", text: $model.addressInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(fetch)
                    .onChange(of: model.addressInput) {
                        model.clearInstallError()
                    }
                if model.installPhase == .fetching {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Install…", action: fetch)
                    .disabled(!model.canSubmitAddress)
            }
            if case let .failed(message) = model.installPhase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if let storageError = registry.storageError {
                Label(storageError, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func fetch() {
        Task { await model.fetchPendingInstall() }
    }
}

private struct AddonRow: View {
    let addon: InstalledAddon
    let registry: AddonRegistry

    @Environment(\.openURL) private var openURL
    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AddonLogo(url: addon.manifest.logo)
            AddonSummary(manifest: addon.manifest)
            Spacer(minLength: 12)

            if let configureURL = addon.configureURL {
                Button("Configure") {
                    openURL(configureURL)
                }
            }
            Toggle("Enabled", isOn: enabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Enable \(addon.manifest.name)")
            Button(role: .destructive) {
                isConfirmingRemoval = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Uninstall")
            .accessibilityLabel("Uninstall \(addon.manifest.name)")
        }
        .padding(.vertical, 8)
        .opacity(addon.isEnabled ? 1 : 0.55)
        .confirmationDialog(
            "Uninstall “\(addon.manifest.name)”?",
            isPresented: $isConfirmingRemoval
        ) {
            Button("Uninstall", role: .destructive) {
                Task { await registry.uninstall(addonID: addon.id) }
            }
        } message: {
            Text("Its catalogs and results will no longer appear. You can install it again by its address.")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding {
            addon.isEnabled
        } set: { isEnabled in
            Task { await registry.setEnabled(isEnabled, addonID: addon.id) }
        }
    }
}

private struct AddonLogo: View {
    let url: URL?

    var body: some View {
        RemoteImage(url: url, maxPointSize: 48, placeholderSystemImage: "puzzlepiece.extension", contentMode: .fit)
            .frame(width: 48, height: 48)
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityHidden(true)
    }
}

private struct AddonSummary: View {
    let manifest: AddonManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(manifest.name)
                    .font(.headline)
                Text("v\(manifest.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let description = manifest.description {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(AddonsModel.summary(of: manifest))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Shows what an add-on is before the user commits to installing it.
private struct AddonInstallSheet: View {
    let addon: InstalledAddon
    let install: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                AddonLogo(url: addon.manifest.logo)
                AddonSummary(manifest: addon.manifest)
            }

            Text(addon.address.manifestURL.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)

            if addon.manifest.behaviorHints.adult {
                Label("This add-on is marked as containing adult content.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            Text("Add-ons are made by third parties. Install only add-ons you trust.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Install", action: install)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
