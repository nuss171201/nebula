import Foundation
import Observation

/// The third-party code the app ships and the licences it comes under, as listed in
/// `Config/ThirdParty.json`. The licence texts themselves are files next to it in the bundle.
public struct ThirdPartyCatalog: Decodable, Sendable, Equatable {
    public struct Component: Decodable, Sendable, Equatable, Identifiable {
        public var name: String
        /// Empty where a prebuilt library does not say which version it contains.
        public var version: String
        public var license: String
        public var url: URL?
        /// Names of the licence files, in the order to show them.
        public var files: [String]
        /// The group it is listed in. The same library can be in two (OpenSSL is in both engines).
        public internal(set) var groupTitle = ""

        public var id: String { "\(groupTitle)|\(name)|\(version)" }

        private enum CodingKeys: String, CodingKey {
            case name, version, license, url, files
        }

        public var title: String {
            version.isEmpty ? name : "\(name) \(version)"
        }
    }

    public struct Group: Decodable, Sendable, Equatable, Identifiable {
        public var title: String
        /// How this part is included in the app (a separate library, or linked in).
        public var note: String
        public var components: [Component]

        public var id: String { title }
    }

    /// Where the source of the replaceable libraries comes from, and how to replace them.
    public var sourceNote: String
    public var groups: [Group]

    private enum CodingKeys: String, CodingKey {
        case sourceNote, groups
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceNote = try container.decode(String.self, forKey: .sourceNote)
        groups = try container.decode([Group].self, forKey: .groups)
        for index in groups.indices {
            for position in groups[index].components.indices {
                groups[index].components[position].groupTitle = groups[index].title
            }
        }
    }

    /// Reads the list from a folder that holds `ThirdParty.json`; `nil` if it is not there or cannot be read.
    public static func load(from directory: URL) -> ThirdPartyCatalog? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("ThirdParty.json")) else { return nil }
        return try? JSONDecoder().decode(ThirdPartyCatalog.self, from: data)
    }

    /// Every licence file the list names, once each.
    public var allFiles: [String] {
        var seen = Set<String>()
        return groups.flatMap(\.components).flatMap(\.files).filter { seen.insert($0).inserted }
    }
}

/// What the Acknowledgements window shows: the components, and the licence texts of the chosen one.
@MainActor
@Observable
public final class AcknowledgementsModel {
    public static let windowID = "acknowledgements"

    public let catalog: ThirdPartyCatalog?
    public var selection: ThirdPartyCatalog.Component.ID? {
        didSet {
            if selection != oldValue {
                loadTexts()
            }
        }
    }

    /// The chosen component's licence files with their text, in order.
    public private(set) var texts: [(file: String, text: String)] = []

    @ObservationIgnored private let licensesDirectory: URL?

    /// - Parameters:
    ///   - resources: The folder holding `ThirdParty.json` and a `Licenses` folder (the app's resources).
    public init(resources: URL?) {
        catalog = resources.flatMap(ThirdPartyCatalog.load(from:))
        licensesDirectory = resources?.appendingPathComponent("Licenses", isDirectory: true)
        selection = catalog?.groups.first?.components.first?.id
        loadTexts()
    }

    public var selectedComponent: ThirdPartyCatalog.Component? {
        catalog?.groups.flatMap(\.components).first { $0.id == selection }
    }

    private func loadTexts() {
        guard let component = selectedComponent, let licensesDirectory else {
            texts = []
            return
        }
        texts = component.files.map { file in
            // A name from the list, never a path: nothing outside the folder can be read through it.
            let name = URL(fileURLWithPath: file).lastPathComponent
            let text = (try? String(contentsOf: licensesDirectory.appendingPathComponent(name), encoding: .utf8))
                ?? "This licence text is missing from the app. It is available from \(component.url?.absoluteString ?? "the project's website")."
            return (file, text)
        }
    }
}
