import Foundation

/// The add-ons installed on first launch, read from the bundled `DefaultAddons.json`
/// (source: `Config/DefaultAddons.json`). Only official metadata and subtitle add-ons
/// belong in that file; streaming sources are never pre-installed.
enum DefaultAddons {
    private struct File: Decodable {
        let addons: [Entry]
    }

    private struct Entry: Decodable {
        let manifestURL: String
    }

    static func addresses(in bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: "DefaultAddons", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.addons.map(\.manifestURL)
    }
}
