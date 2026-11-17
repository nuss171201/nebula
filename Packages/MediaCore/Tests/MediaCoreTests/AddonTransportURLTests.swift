import Foundation
@testable import MediaCore
import Testing

@Suite("Add-on URL normalisation")
struct AddonTransportURLTests {
    @Test("Accepts the forms users paste and normalises them to an https manifest URL", arguments: [
        ("https://example.com/manifest.json", "https://example.com/manifest.json"),
        ("  https://example.com/manifest.json\n", "https://example.com/manifest.json"),
        ("stremio://example.com/manifest.json", "https://example.com/manifest.json"),
        ("example.com/manifest.json", "https://example.com/manifest.json"),
        ("https://example.com", "https://example.com/manifest.json"),
        ("https://example.com/", "https://example.com/manifest.json"),
        ("https://example.com/addon//", "https://example.com/addon/manifest.json"),
        ("https://example.com/cfg%7Cabc/manifest.json", "https://example.com/cfg%7Cabc/manifest.json"),
        ("https://example.com/manifest.json#section", "https://example.com/manifest.json"),
        ("http://127.0.0.1:7000/manifest.json", "http://127.0.0.1:7000/manifest.json"),
        ("http://localhost:7000", "http://localhost:7000/manifest.json"),
        ("http://[::1]:7000/manifest.json", "http://[::1]:7000/manifest.json"),
    ])
    func normalises(input: String, expected: String) throws {
        let url = try AddonTransportURL(userInput: input)
        #expect(url.manifestURL.absoluteString == expected)
    }

    @Test("Base URL is the manifest URL without the file name")
    func baseURL() throws {
        let url = try AddonTransportURL(userInput: "https://example.com/some/config/manifest.json")
        #expect(url.baseURL.absoluteString == "https://example.com/some/config/")
    }

    @Test("Rejects input that cannot be an add-on URL", arguments: [
        ("", AddonURLError.empty),
        ("   \n", AddonURLError.empty),
        ("ftp://example.com/manifest.json", AddonURLError.unsupportedScheme("ftp")),
        ("magnet://example", AddonURLError.unsupportedScheme("magnet")),
        ("http://example.com/manifest.json", AddonURLError.insecureHost("example.com")),
        ("https:///manifest.json", AddonURLError.malformed),
    ])
    func rejects(input: String, expected: AddonURLError) {
        #expect(throws: expected) {
            try AddonTransportURL(userInput: input)
        }
    }

    @Test("Round-trips through Codable")
    func codable() throws {
        let original = try AddonTransportURL(userInput: "https://example.com/manifest.json")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AddonTransportURL.self, from: data)
        #expect(decoded == original)
    }
}
