import Foundation
import MediaCore
import MediaLibrary
import Observation

/// Why an add-on could not be installed.
public enum AddonInstallError: Error, Equatable, Sendable {
    case invalidAddress(AddonURLError)
    case unreachable(AddonError)
    case alreadyInstalled
    case storage

    public var userMessage: String {
        switch self {
        case .invalidAddress(.empty):
            "Enter the address of an add-on."
        case .invalidAddress(.insecureHost):
            "Add-ons must use a secure (https) address."
        case .invalidAddress:
            "That does not look like an add-on address."
        case let .unreachable(error):
            "Could not load the add-on. \(error.userMessage)"
        case .alreadyInstalled:
            "This add-on is already installed."
        case .storage:
            "The add-on could not be saved."
        }
    }
}

/// The single source of truth for which add-ons are installed. Screens read
/// `addons`; every change goes through here so memory and disk stay in step.
@MainActor
@Observable
public final class AddonRegistry {
    static let didInstallDefaults = SettingKey<Bool>("addons.didInstallDefaults", default: false)

    public private(set) var addons: [InstalledAddon] = []
    /// `false` until the stored list has been read and first-run setup has finished.
    public private(set) var isReady = false
    /// Set when the default add-ons could not be fetched on first run.
    public private(set) var setupError: String?
    /// Set when a change could not be written to disk.
    public private(set) var storageError: String?

    @ObservationIgnored private let client: AddonClient
    @ObservationIgnored private let store: AddonStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let defaultAddresses: [String]
    @ObservationIgnored private var hasStarted = false

    public init(client: AddonClient, store: AddonStore, settings: SettingsStore, defaultAddresses: [String]) {
        self.client = client
        self.store = store
        self.settings = settings
        self.defaultAddresses = defaultAddresses
    }

    /// Reads the installed add-ons, installs the defaults on first run, then quietly
    /// refreshes every manifest. Safe to call more than once.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            addons = try await store.all()
        } catch {
            storageError = "Your installed add-ons could not be read."
        }
        // Stored manifests are enough to draw the UI; do not wait for the network.
        isReady = !addons.isEmpty
        await installDefaultsIfNeeded()
        isReady = true
        await refreshManifests()
    }

    /// Tries first-run setup again after it failed (for example, offline at first launch).
    public func retrySetup() async {
        setupError = nil
        await installDefaultsIfNeeded()
    }

    /// Fetches the manifest for an address the user typed, without installing it.
    public func preview(address input: String) async throws(AddonInstallError) -> InstalledAddon {
        let address: AddonTransportURL
        do {
            address = try AddonTransportURL(userInput: input)
        } catch {
            throw .invalidAddress(error)
        }
        guard !addons.contains(where: { $0.address == address }) else { throw .alreadyInstalled }
        do {
            return try await InstalledAddon(address: address, manifest: client.manifest(at: address))
        } catch {
            throw .unreachable(error)
        }
    }

    public func install(_ addon: InstalledAddon) async throws(AddonInstallError) {
        guard !addons.contains(where: { $0.id == addon.id }) else { throw .alreadyInstalled }
        do {
            try await store.install(addon)
        } catch {
            throw .storage
        }
        addons.append(addon)
    }

    public func uninstall(addonID id: String) async {
        addons.removeAll { $0.id == id }
        await persist { try await $0.remove(addonID: id) }
    }

    public func setEnabled(_ isEnabled: Bool, addonID id: String) async {
        guard let index = addons.firstIndex(where: { $0.id == id }), addons[index].isEnabled != isEnabled else { return }
        addons[index].isEnabled = isEnabled
        await persist { try await $0.setEnabled(isEnabled, addonID: id) }
    }

    /// Moves add-ons within the list, with the same semantics as `Array.move(fromOffsets:toOffset:)`.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) async {
        let moving = source.map { addons[$0] }
        let insertion = destination - source.count(in: 0 ..< destination)
        var reordered = addons.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        reordered.insert(contentsOf: moving, at: min(max(insertion, 0), reordered.count))
        guard reordered != addons else { return }
        addons = reordered
        let ids = reordered.map(\.id)
        await persist { try await $0.reorder(addonIDs: ids) }
    }

    // MARK: - Private

    private func persist(_ change: @Sendable (AddonStore) async throws -> Void) async {
        do {
            try await change(store)
            storageError = nil
        } catch {
            storageError = "Your change could not be saved and may be lost when you quit."
        }
    }

    private func installDefaultsIfNeeded() async {
        guard await (try? settings.value(for: Self.didInstallDefaults)) != true else { return }

        let addresses = defaultAddresses.compactMap { try? AddonTransportURL(userInput: $0) }
        let missing = addresses.filter { address in !addons.contains { $0.address == address } }
        let fetched = await fetchManifests(for: missing)

        for address in missing {
            guard let manifest = fetched[address] else { continue }
            try? await install(InstalledAddon(address: address, manifest: manifest))
        }

        if addresses.allSatisfy({ address in addons.contains { $0.address == address } }) {
            try? await settings.set(true, for: Self.didInstallDefaults)
            setupError = nil
        } else {
            setupError = "The default add-ons could not be loaded. Check your internet connection."
        }
    }

    /// Picks up manifest changes (new catalogs, new version) published since install.
    private func refreshManifests() async {
        let fetched = await fetchManifests(for: addons.map(\.address))
        for (address, manifest) in fetched {
            guard let index = addons.firstIndex(where: { $0.address == address }),
                  addons[index].manifest != manifest
            else { continue }
            addons[index].manifest = manifest
            let id = addons[index].id
            try? await store.updateManifest(manifest, forAddonID: id)
        }
    }

    private func fetchManifests(for addresses: [AddonTransportURL]) async -> [AddonTransportURL: AddonManifest] {
        await withTaskGroup(of: (AddonTransportURL, AddonManifest?).self) { group in
            for address in addresses {
                group.addTask { [client] in
                    await (address, try? client.manifest(at: address))
                }
            }
            var result: [AddonTransportURL: AddonManifest] = [:]
            for await (address, manifest) in group {
                result[address] = manifest
            }
            return result
        }
    }
}
