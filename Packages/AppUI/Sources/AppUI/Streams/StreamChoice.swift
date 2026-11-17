import Foundation
import MediaCore

/// Picture height classes streams are grouped by.
public enum StreamQuality: Int, Sendable, Comparable, CaseIterable {
    case sd = 480
    case hd720 = 720
    case hd1080 = 1080
    case qhd1440 = 1440
    case uhd4K = 2160

    public var label: String {
        switch self {
        case .sd: "SD"
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .qhd1440: "1440p"
        case .uhd4K: "4K"
        }
    }

    public static func < (lhs: StreamQuality, rhs: StreamQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Reads quality and size out of the free text add-ons describe streams with.
public enum StreamTextParser {
    /// The picture quality a description mentions: `2160p`, `4K`, `1080p`, `720p`, `480p`, …
    public static func quality(in text: String) -> StreamQuality? {
        let lowered = text.lowercased()
        // Release names join words with dots ("Film.1080p.WEB"), which the default notion of a
        // word treats as one word; the simple one breaks at every change between letters or
        // digits and anything else.
        func mentions(_ pattern: Regex<Substring>) -> Bool {
            lowered.contains(pattern.wordBoundaryKind(.simple))
        }
        if mentions(/\b(?:2160p|4k|uhd)\b/) {
            return .uhd4K
        }
        if mentions(/\b1440p\b/) {
            return .qhd1440
        }
        if mentions(/\b(?:1080p|1080i|fhd)\b/) {
            return .hd1080
        }
        if mentions(/\b720p\b/) {
            return .hd720
        }
        if mentions(/\b(?:480p|576p|360p|sd|dvdrip)\b/) {
            return .sd
        }
        return nil
    }

    /// The largest size a description mentions (`1.4 GB`, `700MB`), in bytes.
    public static func size(in text: String) -> Int64? {
        let matches = text.matches(of: /(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|TiB|GiB|MiB)\b/.ignoresCase())
        let sizes = matches.compactMap { match -> Int64? in
            guard let number = Double(match.output.1.replacingOccurrences(of: ",", with: ".")) else { return nil }
            let unit: Double = switch match.output.2.lowercased() {
            case "tb", "tib": 1_099_511_627_776
            case "gb", "gib": 1_073_741_824
            default: 1_048_576
            }
            return Int64(number * unit)
        }
        return sizes.max()
    }
}

/// One stream as the list shows it: the add-on's stream plus what could be read out of it.
public struct StreamChoice: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Fetched from other people's computers while it plays.
        case torrent
        /// A file on a web server.
        case direct
        case youTube
        /// A web page to open in the browser.
        case external
    }

    public let id: String
    public let stream: StreamItem
    public let addonID: String
    public let addonName: String
    public let quality: StreamQuality?
    public let sizeBytes: Int64?

    /// - Parameter position: The stream's place in its add-on's answer.
    public init(stream: StreamItem, addonID: String, addonName: String, position: Int) {
        self.stream = stream
        self.addonID = addonID
        self.addonName = addonName
        id = "\(addonID)#\(position)"
        let text = [stream.name, stream.details, stream.behaviorHints.filename].compactMap(\.self).joined(separator: "\n")
        quality = StreamTextParser.quality(in: text)
        sizeBytes = stream.behaviorHints.videoSize ?? StreamTextParser.size(in: text)
    }

    public var kind: Kind {
        switch stream.source {
        case .torrent: .torrent
        case .url: .direct
        case .youTube: .youTube
        case .external: .external
        }
    }

    /// The first line: the add-on's name for the stream, on one line.
    public var title: String {
        let name = (stream.name ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
        return name.isEmpty ? addonName : name
    }

    public var detail: String? {
        stream.details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public var sizeText: String? {
        sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    public var kindLabel: String {
        switch kind {
        case .torrent: "Torrent"
        case .direct: "Web"
        case .youTube: "YouTube"
        case .external: "Opens in Browser"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

/// How the stream list is ordered.
public enum StreamSort: String, Sendable, CaseIterable, Identifiable, Codable {
    case quality, size, source

    public var id: Self { self }

    public var title: String {
        switch self {
        case .quality: "Quality"
        case .size: "Size"
        case .source: "Add-on"
        }
    }
}

/// A titled run of streams.
public struct StreamGroup: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var choices: [StreamChoice]

    /// Arranges streams for display.
    /// - Parameter choices: In the order they arrived: add-on by add-on, each in the add-on's own order.
    public static func groups(of choices: [StreamChoice], by sort: StreamSort) -> [StreamGroup] {
        guard !choices.isEmpty else { return [] }
        // Larger first; streams of unknown size keep their order after the known ones.
        func bySize(_ list: [StreamChoice]) -> [StreamChoice] {
            let known = list.filter { $0.sizeBytes != nil }.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
            return known + list.filter { $0.sizeBytes == nil }
        }
        switch sort {
        case .quality:
            var groups = StreamQuality.allCases.reversed().compactMap { quality -> StreamGroup? in
                let matching = choices.filter { $0.quality == quality }
                return matching.isEmpty ? nil : StreamGroup(id: quality.label, title: quality.label, choices: bySize(matching))
            }
            let unknown = choices.filter { $0.quality == nil }
            if !unknown.isEmpty {
                groups.append(StreamGroup(id: "other", title: groups.isEmpty ? "Streams" : "Other", choices: bySize(unknown)))
            }
            return groups
        case .size:
            return [StreamGroup(id: "all", title: "Largest First", choices: bySize(choices))]
        case .source:
            var order: [String] = []
            var byAddon: [String: [StreamChoice]] = [:]
            for choice in choices {
                if byAddon[choice.addonID] == nil {
                    order.append(choice.addonID)
                }
                byAddon[choice.addonID, default: []].append(choice)
            }
            return order.map { StreamGroup(id: $0, title: byAddon[$0]?.first?.addonName ?? "", choices: byAddon[$0] ?? []) }
        }
    }
}

/// What is remembered about the stream last played for a title, to offer the same again:
/// for the next episode of a series, or the next time a film is opened.
public struct LastStreamChoice: Sendable, Equatable, Codable {
    public var addonID: String
    /// Streams of one release share this across episodes, when the add-on says so.
    public var bingeGroup: String?
    public var qualityHeight: Int?
    public var isTorrent: Bool

    public init(_ choice: StreamChoice) {
        addonID = choice.addonID
        bingeGroup = choice.stream.behaviorHints.bingeGroup
        qualityHeight = choice.quality?.rawValue
        isTorrent = choice.kind == .torrent
    }

    /// The stream in a new list that is most like the one played last time: same add-on and
    /// release group if the add-on names groups, else same add-on and quality. `nil` if nothing is alike.
    public func bestMatch(in choices: [StreamChoice]) -> StreamChoice? {
        let sameAddon = choices.filter { $0.addonID == addonID }
        if let bingeGroup, let match = sameAddon.first(where: { $0.stream.behaviorHints.bingeGroup == bingeGroup }) {
            return match
        }
        return sameAddon.first { $0.quality?.rawValue == qualityHeight && ($0.kind == .torrent) == isTorrent }
    }
}

/// Where the last-used source of each title is kept. Implemented on the app's database.
public protocol StreamChoiceMemory: Sendable {
    func lastChoice(for titleID: String) async -> LastStreamChoice?
    func remember(_ choice: LastStreamChoice, for titleID: String) async
}
