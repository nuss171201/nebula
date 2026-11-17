import Foundation

/// One video, audio or subtitle track of the open file.
public struct MediaTrack: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case video
        case audio
        case subtitle = "sub"
    }

    public var kind: Kind
    /// The engine's number for this track within its kind (1, 2, …). Stable while the file is open.
    public var number: Int
    public var title: String?
    /// Language tag as the file gives it, usually ISO 639-2 (`eng`); `nil` when untagged.
    public var language: String?
    public var codec: String?
    public var isDefault: Bool
    public var isForced: Bool
    /// Loaded from a separate file or URL rather than found inside the media.
    public var isExternal: Bool
    public var isSelected: Bool
    /// Audio only.
    public var channelCount: Int?
    /// Video only, in pixels.
    public var width: Int?
    public var height: Int?
    public var framesPerSecond: Double?
    /// Video only: the Dolby Vision profile, when the track carries Dolby Vision.
    public var dolbyVisionProfile: Int?

    public init(
        kind: Kind,
        number: Int,
        title: String? = nil,
        language: String? = nil,
        codec: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isExternal: Bool = false,
        isSelected: Bool = false,
        channelCount: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        framesPerSecond: Double? = nil,
        dolbyVisionProfile: Int? = nil
    ) {
        self.kind = kind
        self.number = number
        self.title = title
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
        self.isSelected = isSelected
        self.channelCount = channelCount
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.dolbyVisionProfile = dolbyVisionProfile
    }

    public var id: String {
        "\(kind.rawValue)\(number)"
    }

    /// One entry of the engine's `track-list`.
    init?(node: MPVNode) {
        guard let kind = node["type"]?.text.flatMap(Kind.init(rawValue:)), let number = node["id"]?.integer else { return nil }
        self.init(
            kind: kind,
            number: number,
            title: node["title"]?.text,
            language: node["lang"]?.text.flatMap { $0 == "und" ? nil : $0 },
            codec: node["codec"]?.text,
            isDefault: node["default"]?.isTrue ?? false,
            isForced: node["forced"]?.isTrue ?? false,
            isExternal: node["external"]?.isTrue ?? false,
            isSelected: node["selected"]?.isTrue ?? false,
            channelCount: node["demux-channel-count"]?.integer,
            width: node["demux-w"]?.integer,
            height: node["demux-h"]?.integer,
            framesPerSecond: node["demux-fps"]?.number,
            dolbyVisionProfile: node["dolby-vision-profile"]?.integer
        )
    }

    static func list(from node: MPVNode) -> [MediaTrack] {
        node.elements.compactMap(MediaTrack.init(node:))
    }
}

/// A named point in the file.
public struct MediaChapter: Sendable, Hashable, Identifiable {
    /// Position in the file's chapter list, from 0.
    public var index: Int
    public var title: String
    /// Seconds from the start.
    public var start: Double

    public init(index: Int, title: String, start: Double) {
        self.index = index
        self.title = title
        self.start = start
    }

    public var id: Int { index }

    static func list(from node: MPVNode) -> [MediaChapter] {
        node.elements.enumerated().compactMap { index, entry in
            guard let start = entry["time"]?.number else { return nil }
            return MediaChapter(index: index, title: entry["title"]?.text ?? "Chapter \(index + 1)", start: max(start, 0))
        }
    }
}

/// One entry of the play queue.
public struct PlaylistEntry: Sendable, Hashable, Identifiable {
    /// Position in the queue, from 0.
    public var index: Int
    /// The file path or URL as given to the engine.
    public var location: String
    public var title: String?
    public var isCurrent: Bool

    public init(index: Int, location: String, title: String? = nil, isCurrent: Bool = false) {
        self.index = index
        self.location = location
        self.title = title
        self.isCurrent = isCurrent
    }

    public var id: Int { index }

    /// The title if the engine knows one, otherwise the file name.
    public var displayName: String {
        if let title {
            return title
        }
        let name = (location as NSString).lastPathComponent
        return name.isEmpty ? location : (name.removingPercentEncoding ?? name)
    }

    static func list(from node: MPVNode) -> [PlaylistEntry] {
        node.elements.enumerated().compactMap { index, entry in
            guard let location = entry["filename"]?.text else { return nil }
            return PlaylistEntry(
                index: index,
                location: location,
                title: entry["title"]?.text,
                isCurrent: entry["current"]?.isTrue ?? false
            )
        }
    }
}
