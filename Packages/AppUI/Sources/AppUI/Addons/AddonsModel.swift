import Foundation
import MediaCore
import Observation

/// The Add-ons screen: install by address (with a confirmation step that shows what
/// the add-on is), enable, disable, reorder, uninstall.
@MainActor
@Observable
public final class AddonsModel {
    public enum InstallPhase: Equatable, Sendable {
        case idle
        /// Fetching the manifest for the typed address.
        case fetching
        case failed(String)
    }

    public var addressInput = ""
    public private(set) var installPhase: InstallPhase = .idle
    /// An add-on whose manifest has been fetched and is waiting for the user to confirm.
    public var pendingInstall: InstalledAddon?

    public let registry: AddonRegistry

    public init(registry: AddonRegistry) {
        self.registry = registry
    }

    public var canSubmitAddress: Bool {
        installPhase != .fetching && !addressInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Step 1: look up the typed address and present what was found.
    public func fetchPendingInstall() async {
        guard canSubmitAddress else { return }
        installPhase = .fetching
        do {
            pendingInstall = try await registry.preview(address: addressInput)
            installPhase = .idle
        } catch {
            installPhase = .failed(error.userMessage)
        }
    }

    /// Step 2: the user confirmed.
    public func confirmInstall() async {
        guard let addon = pendingInstall else { return }
        pendingInstall = nil
        do {
            try await registry.install(addon)
            addressInput = ""
            installPhase = .idle
        } catch {
            installPhase = .failed(error.userMessage)
        }
    }

    public func cancelInstall() {
        pendingInstall = nil
    }

    public func clearInstallError() {
        if case .failed = installPhase {
            installPhase = .idle
        }
    }

    /// One line describing what an add-on provides, for example "Catalogs, metadata · Movies, Series".
    public static func summary(of manifest: AddonManifest) -> String {
        let names = manifest.resources.map(\.name)
        let provides = [
            names.contains(ManifestResource.catalog) ? "catalogs" : nil,
            names.contains(ManifestResource.meta) ? "metadata" : nil,
            names.contains(ManifestResource.stream) ? "streams" : nil,
            names.contains(ManifestResource.subtitles) ? "subtitles" : nil,
        ].compactMap(\.self).joined(separator: ", ")
        let types = manifest.types.sorted(by: MediaType.displayOrder).map(\.pluralTitle).joined(separator: ", ")
        let capitalised = provides.prefix(1).uppercased() + provides.dropFirst()
        return [capitalised, types].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
