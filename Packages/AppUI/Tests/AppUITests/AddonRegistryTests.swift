import AddonTestSupport
@testable import AppUI
import Foundation
import MediaCore
import MediaLibrary
import Testing

@MainActor
@Suite("Add-on registry")
struct AddonRegistryTests {
    @Test("First launch installs the default add-ons, in order, exactly once")
    func installsDefaults() async throws {
        let harness = try await AddonHarness.make()
        harness.serveSecondAddon(prefix: "subs", name: "Subtitles")
        let defaults = try [harness.address().manifestURL.absoluteString, harness.address("subs").manifestURL.absoluteString]

        let registry = harness.registry(defaults: defaults)
        #expect(!registry.isReady)
        await registry.start()
        #expect(registry.isReady)
        #expect(registry.setupError == nil)
        #expect(registry.addons.map(\.manifest.name) == ["Test Catalog", "Subtitles"])

        // The user removes one; the next launch must not bring it back.
        await registry.uninstall(addonID: registry.addons[1].id)
        let relaunched = harness.registry(defaults: defaults)
        await relaunched.start()
        #expect(relaunched.addons.map(\.manifest.name) == ["Test Catalog"])
    }

    @Test("If a default add-on is unreachable, setup reports it and can be retried")
    func defaultsFailThenRecover() async throws {
        let harness = try await AddonHarness.make()
        let missing = try harness.address("later").manifestURL.absoluteString
        let defaults = try [harness.address().manifestURL.absoluteString, missing]

        let registry = harness.registry(defaults: defaults)
        await registry.start()
        #expect(registry.isReady)
        #expect(registry.addons.count == 1)
        #expect(registry.setupError != nil)

        harness.serveSecondAddon(prefix: "later", name: "Late Add-on")
        await registry.retrySetup()
        #expect(registry.setupError == nil)
        #expect(registry.addons.map(\.manifest.name) == ["Test Catalog", "Late Add-on"])
    }

    @Test("Previewing an address validates it before anything is installed")
    func preview() async throws {
        let harness = try await AddonHarness.make()
        let registry = harness.registry()
        await registry.start()

        let found = try await registry.preview(address: harness.baseURL.absoluteString)
        #expect(found.manifest.name == "Test Catalog")
        #expect(registry.addons.isEmpty)

        await #expect(throws: AddonInstallError.invalidAddress(.empty)) {
            try await registry.preview(address: "  ")
        }
        await #expect(throws: AddonInstallError.invalidAddress(.insecureHost("example.com"))) {
            try await registry.preview(address: "http://example.com/manifest.json")
        }
        await #expect(throws: AddonInstallError.unreachable(.http(.badStatus(404)))) {
            try await registry.preview(address: harness.baseURL.absoluteString + "nothing-here")
        }

        try await registry.install(found)
        await #expect(throws: AddonInstallError.alreadyInstalled) {
            try await registry.preview(address: harness.baseURL.absoluteString)
        }
        await #expect(throws: AddonInstallError.alreadyInstalled) {
            try await registry.install(found)
        }
    }

    @Test("Enable, reorder and uninstall are persisted")
    func mutationsPersist() async throws {
        let harness = try await AddonHarness.make()
        harness.serveSecondAddon(prefix: "b", name: "B")
        harness.serveSecondAddon(prefix: "c", name: "C")
        let registry = harness.registry()
        await registry.start()
        for prefix in ["", "b", "c"] {
            try await registry.install(registry.preview(address: harness.baseURL.absoluteString + prefix))
        }
        #expect(registry.addons.map(\.manifest.name) == ["Test Catalog", "B", "C"])

        await registry.setEnabled(false, addonID: registry.addons[1].id)
        await registry.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(registry.addons.map(\.manifest.name) == ["C", "Test Catalog", "B"])
        await registry.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(registry.addons.map(\.manifest.name) == ["Test Catalog", "B", "C"])
        await registry.uninstall(addonID: registry.addons[0].id)
        #expect(registry.storageError == nil)

        let reloaded = harness.registry()
        await reloaded.start()
        #expect(reloaded.addons.map(\.manifest.name) == ["B", "C"])
        #expect(reloaded.addons.map(\.isEnabled) == [false, true])
    }

    @Test("A manifest that changed on the server is picked up at the next launch")
    func refreshesManifests() async throws {
        let harness = try await AddonHarness.make()
        let registry = harness.registry()
        await registry.start()
        try await registry.install(registry.preview(address: harness.baseURL.absoluteString))

        harness.server.respond(to: "/manifest.json", with: .json(AddonFixtures.manifestJSON(name: "Renamed")))
        let relaunched = harness.registry()
        await relaunched.start()
        #expect(relaunched.addons.first?.manifest.name == "Renamed")

        // And the refreshed manifest was saved, so it survives being offline next time.
        harness.server.respond(to: "/manifest.json", with: .status(500))
        let offline = harness.registry()
        await offline.start()
        #expect(offline.addons.first?.manifest.name == "Renamed")
    }
}
