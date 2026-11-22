import AppUI
import Foundation

/// The add-ons installed without being asked for, read from the bundled `DefaultAddons.json`
/// (source: `Config/DefaultAddons.json`). Only metadata and subtitle add-ons belong in that
/// file; streaming sources are never pre-installed.
enum DefaultAddons {
    private struct File: Decodable {
        let addons: [Entry]
    }

    private struct Entry: Decodable {
        let manifestURL: String
        /// The round of defaults the add-on came in; the first when the file does not say.
        let since: Int?
    }

    static func addons(in bundle: Bundle) -> [DefaultAddon] {
        guard let url = bundle.url(forResource: "DefaultAddons", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.addons.map { DefaultAddon(address: $0.manifestURL, round: $0.since ?? 1) }
    }
}
