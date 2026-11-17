import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary

/// A mock add-on server plus the client and stores a view model needs.
@MainActor
struct AddonHarness {
    let server: MockAddonServer
    let baseURL: URL
    let client: AddonClient
    let database: LibraryDatabase

    /// Starts a server. The standard manifest is served at `/manifest.json`.
    static func make(retry: RetryPolicy = .none) async throws -> AddonHarness {
        let server = try MockAddonServer()
        let baseURL = try await server.start()
        server.respond(to: "/manifest.json", with: .json(AddonFixtures.manifestJSON()))
        let http = URLSessionHTTPClient(userAgent: "Tests/1.0", retryPolicy: retry)
        return try AddonHarness(
            server: server,
            baseURL: baseURL,
            client: AddonClient(http: http, timeout: .seconds(5)),
            database: .inMemory()
        )
    }

    /// The address of an add-on served under `prefix` on the mock server ("" for the root).
    func address(_ prefix: String = "") throws -> AddonTransportURL {
        try AddonTransportURL(userInput: baseURL.absoluteString + prefix)
    }

    /// The root add-on, as if installed.
    func installedAddon() async throws -> InstalledAddon {
        let address = try address()
        return try await InstalledAddon(address: address, manifest: client.manifest(at: address))
    }

    func registry(defaults: [String] = []) -> AddonRegistry {
        AddonRegistry(
            client: client,
            store: AddonStore(database: database),
            settings: SettingsStore(database: database),
            defaultAddresses: defaults
        )
    }

    /// Serves a second add-on with its own id and name under `/<prefix>/`.
    func serveSecondAddon(prefix: String, name: String) {
        server.respond(
            to: "/\(prefix)/manifest.json",
            with: .json(AddonFixtures.manifestJSON(id: "test.\(prefix)", name: name))
        )
    }
}
