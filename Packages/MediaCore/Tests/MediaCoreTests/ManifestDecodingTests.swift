import AddonTestSupport
import Foundation
@testable import MediaCore
import Testing

@Suite("Manifest parsing")
struct ManifestDecodingTests {
    private func decode(_ json: String) throws -> AddonManifest {
        try JSONDecoder().decode(AddonManifest.self, from: Data(json.utf8))
    }

    @Test("Reads a metadata add-on's manifest")
    func standardManifest() throws {
        let manifest = try decode(AddonFixtures.manifestJSON())
        #expect(manifest.id == "test.catalog")
        #expect(manifest.version == "1.2.3")
        #expect(manifest.types == [.movie, .series])
        #expect(manifest.resources.map(\.name) == ["catalog", "meta"])
        #expect(manifest.idPrefixes == ["tt"])
        #expect(manifest.catalogs.count == 4)

        let popular = manifest.catalogs[0]
        #expect(popular.displayName == "Popular")
        #expect(popular.isBoardEligible)
        #expect(popular.isSearchable)
        #expect(popular.supportsPaging)
        #expect(popular.selectableExtras.map(\.name) == ["genre"])

        let byYear = manifest.catalogs[1]
        #expect(!byYear.isBoardEligible)
        #expect(!byYear.isSearchable)
        #expect(byYear.isBrowsable)
        #expect(byYear.requiredExtras.first?.options == ["2026", "2025", "2024"])

        let calendar = manifest.catalogs[3]
        #expect(!calendar.isBoardEligible)
        #expect(!calendar.isBrowsable)
        #expect(calendar.extra.first?.optionsLimit == 100)
    }

    @Test("Resources may be bare names or objects with their own restrictions")
    func resourceForms() throws {
        let manifest = try decode("""
        {"id": "a", "name": "A", "types": ["movie", "series"], "idPrefixes": ["tt"],
         "resources": ["catalog", {"name": "stream", "types": ["movie"], "idPrefixes": ["kitsu:"]}, {"bad": true}]}
        """)
        #expect(manifest.resources.count == 2)
        #expect(manifest.supports(resource: "catalog", type: .series, id: "tt1"))
        #expect(!manifest.supports(resource: "catalog", type: .series, id: "xx1"))
        #expect(manifest.supports(resource: "stream", type: .movie, id: "kitsu:5"))
        #expect(!manifest.supports(resource: "stream", type: .movie, id: "tt1"))
        #expect(!manifest.supports(resource: "stream", type: .series, id: "kitsu:5"))
        #expect(!manifest.supports(resource: "subtitles", type: .movie, id: "tt1"))
    }

    @Test("An add-on without id prefixes serves any id")
    func noPrefixes() throws {
        let manifest = try decode(#"{"id": "a", "name": "A", "types": ["movie"], "resources": ["meta"]}"#)
        #expect(manifest.idPrefixes == nil)
        #expect(manifest.supports(resource: "meta", type: .movie, id: "anything"))
    }

    @Test("Legacy catalog parameters are converted to the modern form")
    func legacyExtras() throws {
        let manifest = try decode("""
        {"id": "a", "name": "A", "types": ["movie"], "resources": ["catalog"],
         "catalogs": [{"type": "movie", "id": "old", "genres": ["Action", "Drama"],
                       "extraSupported": ["search", "genre"], "extraRequired": ["genre"]}]}
        """)
        let catalog = try #require(manifest.catalogs.first)
        #expect(catalog.displayName == "old")
        #expect(catalog.extra.map(\.name) == ["search", "genre"])
        #expect(catalog.extraProperty(named: "genre")?.isRequired == true)
        #expect(catalog.extraProperty(named: "genre")?.options == ["Action", "Drama"])
        #expect(!catalog.isSearchable)
        #expect(catalog.isBrowsable)
    }

    @Test("Behaviour hints default to off and tolerate missing or odd values")
    func behaviorHints() throws {
        let plain = try decode(#"{"id": "a", "name": "A"}"#)
        #expect(plain.behaviorHints == ManifestBehaviorHints())

        let hinted = try decode("""
        {"id": "a", "name": "A", "logo": "", "background": "file:///etc/passwd",
         "behaviorHints": {"configurable": true, "adult": "yes", "p2p": true}}
        """)
        #expect(hinted.behaviorHints.configurable)
        #expect(hinted.behaviorHints.p2p)
        #expect(!hinted.behaviorHints.adult)
        #expect(hinted.logo == nil)
        #expect(hinted.background == nil)
    }

    @Test("A manifest without an id or a name is rejected", arguments: [
        #"{"name": "No id"}"#,
        #"{"id": "no.name"}"#,
        #"["not", "an", "object"]"#,
    ])
    func rejects(json: String) {
        #expect(throws: (any Error).self) {
            try decode(json)
        }
    }

    @Test("Survives being stored and loaded again")
    func roundTrip() throws {
        let original = try decode(AddonFixtures.manifestJSON())
        let stored = try JSONEncoder().encode(original)
        let loaded = try JSONDecoder().decode(AddonManifest.self, from: stored)
        #expect(loaded == original)
    }

    @Test("Installed add-ons expose their catalogs and resource providers")
    func installedAddonQueries() throws {
        let catalogAddon = try InstalledAddon(
            address: AddonTransportURL(userInput: "https://one.example.com"),
            manifest: decode(AddonFixtures.manifestJSON())
        )
        var disabled = try InstalledAddon(
            address: AddonTransportURL(userInput: "https://two.example.com"),
            manifest: decode(AddonFixtures.manifestJSON(id: "second"))
        )
        disabled.isEnabled = false
        let addons = [catalogAddon, disabled]

        #expect(addons.catalogSources.count == 4)
        #expect(Set(addons.catalogSources.map(\.id)).count == 4)
        #expect(addons.serving(resource: "meta", type: .movie, id: "tt1").map(\.id) == [catalogAddon.id])
        #expect(addons.serving(resource: "stream", type: .movie, id: "tt1").isEmpty)
        #expect(catalogAddon.configureURL == nil)
    }
}
