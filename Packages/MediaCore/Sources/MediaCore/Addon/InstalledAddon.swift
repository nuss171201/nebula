import Foundation

/// An add-on the user has installed: where it lives, what it says it offers,
/// and whether it is currently switched on.
public struct InstalledAddon: Sendable, Hashable, Identifiable {
    public var address: AddonTransportURL
    public var manifest: AddonManifest
    public var isEnabled: Bool

    public init(address: AddonTransportURL, manifest: AddonManifest, isEnabled: Bool = true) {
        self.address = address
        self.manifest = manifest
        self.isEnabled = isEnabled
    }

    /// Two installs of the same add-on with different configuration have different
    /// addresses, so the address (not the manifest id) is the identity.
    public var id: String {
        address.manifestURL.absoluteString
    }

    /// The add-on's settings page, if it has one.
    public var configureURL: URL? {
        manifest.behaviorHints.configurable ? address.configureURL : nil
    }
}

/// A catalog together with the add-on that serves it.
public struct CatalogSource: Sendable, Hashable, Identifiable {
    public var addon: InstalledAddon
    public var catalog: ManifestCatalog

    public init(addon: InstalledAddon, catalog: ManifestCatalog) {
        self.addon = addon
        self.catalog = catalog
    }

    public var id: String {
        "\(addon.id)|\(catalog.type.rawValue)|\(catalog.id)"
    }
}

public extension [InstalledAddon] {
    /// Every catalog of every enabled add-on, in install order.
    var catalogSources: [CatalogSource] {
        filter(\.isEnabled).flatMap { addon in
            guard addon.manifest.supports(resource: ManifestResource.catalog) else { return [CatalogSource]() }
            return addon.manifest.catalogs.map { CatalogSource(addon: addon, catalog: $0) }
        }
    }

    /// Enabled add-ons that can serve `resource` for this item, in install order.
    func serving(resource: String, type: MediaType, id: String) -> [InstalledAddon] {
        filter { $0.isEnabled && $0.manifest.supports(resource: resource, type: type, id: id) }
    }
}
