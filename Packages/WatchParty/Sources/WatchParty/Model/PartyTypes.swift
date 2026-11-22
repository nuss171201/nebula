import Foundation

/// Names one person's app in a party. Made up afresh for every party, so it says nothing about who they are.
public struct MemberID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// `nil` unless the text is 1 to 64 lower-case letters, digits or hyphens: ids travel through
    /// the signalling server and come back from other people's apps.
    public init?(_ rawValue: String) {
        let allowed = rawValue.unicodeScalars.allSatisfy { scalar in
            ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) || scalar == "-"
        }
        guard allowed, (1 ... 64).contains(rawValue.count) else { return nil }
        self.rawValue = rawValue
    }

    public static func random() -> MemberID {
        // A UUID is always inside the alphabet above.
        MemberID(unchecked: UUID().uuidString.lowercased())
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = MemberID(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a member id"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: MemberID, rhs: MemberID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        rawValue
    }
}

/// Orders the writes to a value everyone in the party shares: the highest wins, everywhere.
public struct RegisterVersion: Hashable, Sendable, Codable, Comparable {
    public var counter: Int
    public var author: MemberID

    public init(counter: Int, author: MemberID) {
        self.counter = counter
        self.author = author
    }

    public static func < (lhs: RegisterVersion, rhs: RegisterVersion) -> Bool {
        (lhs.counter, lhs.author) < (rhs.counter, rhs.author)
    }
}

/// What the party is watching: enough to recognise it and to find it, never where it is played from.
/// Everyone plays their own copy or stream.
public struct PartyContent: Codable, Sendable, Equatable {
    /// A title from a catalog add-on, which another person's app can open the page of.
    public struct CatalogReference: Codable, Sendable, Equatable {
        public var type: String
        public var titleID: String
        public var videoID: String

        public init(type: String, titleID: String, videoID: String) {
            self.type = type
            self.titleID = titleID
            self.videoID = videoID
        }
    }

    /// Tells one video from another.
    public var key: String
    /// What to call it.
    public var title: String
    public var catalog: CatalogReference?

    public init(key: String, title: String, catalog: CatalogReference? = nil) {
        self.key = key
        self.title = title
        self.catalog = catalog
    }

    /// Whether someone with `other` open is watching this. Two catalog videos must be the same
    /// one; a file is taken to be a copy of whatever the party is watching, since two people's
    /// copies of a film rarely have the same name.
    public func matches(_ other: PartyContent) -> Bool {
        if key == other.key {
            return true
        }
        return catalog == nil || other.catalog == nil
    }

    /// Cut down to sizes that are safe to show, whatever another app sent.
    func sanitized() -> PartyContent {
        var copy = self
        copy.key = String(key.prefix(300))
        copy.title = WireLimits.clean(title, limit: WireLimits.titleLength)
        if let catalog {
            copy.catalog = CatalogReference(
                type: String(catalog.type.prefix(40)),
                titleID: String(catalog.titleID.prefix(200)),
                videoID: String(catalog.videoID.prefix(200))
            )
        }
        return copy
    }
}

/// Who may pause, seek and choose what is watched.
public struct RoomSettings: Codable, Sendable, Equatable {
    /// The person who started the party.
    public var hostID: MemberID
    /// `false` leaves the controls to the host alone.
    public var everyoneControls: Bool
    public var version: RegisterVersion

    public init(hostID: MemberID, everyoneControls: Bool, version: RegisterVersion) {
        self.hostID = hostID
        self.everyoneControls = everyoneControls
        self.version = version
    }
}

/// Where the party is in the video, tied to this Mac's clock.
public struct SharedPlayback: Sendable, Equatable {
    /// Why it was last changed.
    public enum Reason: String, Codable, Sendable {
        /// Someone paused, resumed, jumped or changed the speed.
        case user
        /// Paused by itself because someone's video stalled.
        case wait
        /// Resumed by itself once everyone was ready again.
        case resume
        /// A different video was started.
        case content

        public init(from decoder: any Decoder) throws {
            // A reason from a newer version is still a change to follow.
            self = try Reason(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .user
        }
    }

    /// Seconds into the video at `anchor`.
    public var position: Double
    /// When `position` was true, on this Mac's clock.
    public var anchor: TimeInterval
    public var isPaused: Bool
    public var rate: Double
    /// Who the party is waiting for, when it paused by itself.
    public var holder: MemberID?
    public var reason: Reason
    public var version: RegisterVersion

    /// Where the party is at a moment on this Mac's clock.
    public func position(at now: TimeInterval) -> Double {
        isPaused ? position : position + (now - anchor) * rate
    }
}

/// What the party is watching, as a shared value.
public struct SharedContent: Codable, Sendable, Equatable {
    public var content: PartyContent?
    public var version: RegisterVersion
}

/// What one person's player is doing, as they tell the others.
public struct MemberStatus: Codable, Sendable, Equatable {
    public enum Activity: String, Codable, Sendable {
        /// Not watching what the party is watching (nothing open, or something else).
        case away
        /// Has the video open and is getting to where the party is.
        case catchingUp
        case ready
        /// Was in step and is now waiting for data.
        case stalled

        public init(from decoder: any Decoder) throws {
            self = try Activity(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .away
        }
    }

    public var activity: Activity
    /// What they have open, if anything.
    public var title: String?
    public var position: Double?
    public var inVoice: Bool
    public var isMuted: Bool

    public init(activity: Activity, title: String? = nil, position: Double? = nil, inVoice: Bool = false, isMuted: Bool = false) {
        self.activity = activity
        self.title = title
        self.position = position
        self.inVoice = inVoice
        self.isMuted = isMuted
    }

    /// Whether anything but the position differs: the position alone is not news.
    func differsBeyondPosition(from other: MemberStatus) -> Bool {
        var mine = self
        mine.position = other.position
        return mine != other
    }

    func sanitized() -> MemberStatus {
        var copy = self
        copy.title = title.map { WireLimits.clean($0, limit: WireLimits.titleLength) }
        copy.position = position.flatMap { $0.isFinite ? max($0, 0) : nil }
        return copy
    }
}

/// Sizes that text from other people's apps is cut to before it is kept or shown.
enum WireLimits {
    static let nameLength = 40
    static let titleLength = 200
    static let chatLength = 2000

    /// Without control characters or surrounding space, and no longer than `limit`.
    static func clean(_ text: String, limit: Int) -> String {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }))
        return String(visible.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}
