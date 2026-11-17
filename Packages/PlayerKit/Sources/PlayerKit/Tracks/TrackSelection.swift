import Foundation

/// Compares language tags that mean the same thing but are written differently:
/// `en`, `eng`, `en-US`; `fr`, `fra`, `fre`.
public enum LanguageMatcher {
    /// ISO 639-2 "bibliographic" codes whose "terminologic" twin is the one the system knows.
    private static let bibliographicCodes: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces", "dut": "nld",
        "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri",
        "may": "msa", "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    /// A canonical key for a language tag: the two-letter code where one exists, otherwise the
    /// three-letter one. `nil` for empty or undetermined tags.
    public static func canonical(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let primary = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard !primary.isEmpty, primary != "und", primary != "zxx", primary != "mul" else { return nil }
        let code = bibliographicCodes[primary] ?? primary
        return Locale.LanguageCode(code).identifier(.alpha2) ?? code
    }

    public static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let left = canonical(lhs), let right = canonical(rhs) else { return false }
        return left == right
    }

    /// Words that identify a language in a track title: its English name, its own name, and its codes.
    static func titleWords(for language: String) -> [String] {
        guard let code = canonical(language) else { return [] }
        let languageCode = Locale.LanguageCode(code)
        let names = [
            Locale(identifier: "en").localizedString(forLanguageCode: code),
            Locale(identifier: code).localizedString(forLanguageCode: code),
            languageCode.identifier(.alpha3),
            languageCode.identifier(.alpha2),
            bibliographicCodes.first { $0.value == languageCode.identifier(.alpha3) }?.key,
        ]
        var seen = Set<String>()
        return names.compactMap { $0?.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether a free-form title names the language, as a whole word: "English", "Eng 5.1", "[EN]".
    public static func title(_ title: String?, names language: String) -> Bool {
        guard let title, !title.isEmpty else { return false }
        let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return titleWords(for: language).contains { name in
            // Multi-word names ("norwegian bokmål") must all be present.
            name.split(whereSeparator: { !$0.isLetter }).allSatisfy { words.contains(String($0)) }
        }
    }

    /// The name to show for a language tag, in the user's language: "French" for `fra`.
    public static func displayName(for tag: String?, locale: Locale = .current) -> String? {
        guard let code = canonical(tag) else { return nil }
        return locale.localizedString(forLanguageCode: code)
    }
}

/// What the user wants to hear and read by default.
public struct TrackPreferences: Sendable, Equatable, Codable {
    public enum SubtitleMode: String, Sendable, Codable, CaseIterable {
        /// Only when the sound is not in a preferred language (plus forced subtitles).
        case automatic
        /// Whenever a subtitle in a preferred language exists.
        case always
        /// Never, except forced subtitles.
        case off
    }

    /// Languages in order of preference, as any kind of tag (`en`, `eng`, `en-GB`).
    public var audioLanguages: [String]
    public var subtitleLanguages: [String]
    public var subtitleMode: SubtitleMode

    public init(audioLanguages: [String], subtitleLanguages: [String], subtitleMode: SubtitleMode = .automatic) {
        self.audioLanguages = audioLanguages
        self.subtitleLanguages = subtitleLanguages
        self.subtitleMode = subtitleMode
    }

    /// The system's preferred languages for both sound and subtitles.
    public static func system(preferredLanguages: [String] = Locale.preferredLanguages) -> TrackPreferences {
        var seen = Set<String>()
        let languages = preferredLanguages.compactMap(LanguageMatcher.canonical).filter { seen.insert($0).inserted }
        return TrackPreferences(audioLanguages: languages, subtitleLanguages: languages)
    }
}

/// Enough about a track to find "the same one" in another file, such as the next episode.
public struct TrackDescriptor: Sendable, Equatable, Codable {
    public var language: String?
    public var title: String?
    public var codec: String?
    public var channelCount: Int?

    public init(language: String? = nil, title: String? = nil, codec: String? = nil, channelCount: Int? = nil) {
        self.language = language
        self.title = title
        self.codec = codec
        self.channelCount = channelCount
    }

    public init(_ track: MediaTrack) {
        self.init(language: track.language, title: track.title, codec: track.codec, channelCount: track.channelCount)
    }

    /// How well a track matches, or `nil` if it is not the same kind of thing at all.
    /// Language (or, for untagged tracks, the title) must agree; the rest breaks ties.
    func score(_ track: MediaTrack) -> Int? {
        let sameLanguage = LanguageMatcher.matches(language, track.language)
        let bothUntagged = LanguageMatcher.canonical(language) == nil && LanguageMatcher.canonical(track.language) == nil
        let sameTitle = title != nil && title?.caseInsensitiveCompare(track.title ?? "") == .orderedSame
        guard sameLanguage || (bothUntagged && (sameTitle || title == nil)) else { return nil }
        var score = sameLanguage ? 8 : 4
        if sameTitle || (title == nil && track.title == nil) {
            score += 4
        }
        if codec != nil, codec == track.codec {
            score += 2
        }
        if channelCount != nil, channelCount == track.channelCount {
            score += 1
        }
        return score
    }
}

/// What the user last chose for a title or series.
public struct RememberedTracks: Sendable, Equatable, Codable {
    public enum Subtitle: Sendable, Equatable, Codable {
        case off
        case track(TrackDescriptor)
    }

    public var audio: TrackDescriptor?
    public var subtitle: Subtitle?

    public init(audio: TrackDescriptor? = nil, subtitle: Subtitle? = nil) {
        self.audio = audio
        self.subtitle = subtitle
    }
}

/// Which tracks to switch to when a file opens.
public struct TrackSelection: Sendable, Equatable {
    public enum Subtitle: Sendable, Equatable {
        case off
        case track(Int)
    }

    /// The audio track number to use; `nil` leaves the engine's choice alone.
    public var audio: Int?
    /// `nil` leaves the engine's choice alone.
    public var subtitle: Subtitle?
}

/// Decides which audio and subtitle track to use for a file, in this order:
/// what the user chose last time for this title; their language preferences by language
/// tag; a track whose title names a preferred language; otherwise the file's default.
public enum TrackSelector {
    public static func selection(
        tracks: [MediaTrack],
        preferences: TrackPreferences,
        remembered: RememberedTracks?
    ) -> TrackSelection {
        let audioTracks = tracks.filter { $0.kind == .audio }
        let subtitleTracks = tracks.filter { $0.kind == .subtitle }

        let audio = remembered?.audio.flatMap { best(matching: $0, in: audioTracks) }
            ?? preferred(in: audioTracks, languages: preferences.audioLanguages)
        // The language the user will hear: the picked track's, else whatever the engine has selected.
        let audioTrack = audio ?? audioTracks.first(where: \.isSelected) ?? audioTracks.first

        let subtitle: TrackSelection.Subtitle? = switch remembered?.subtitle {
        case .off:
            .off
        case let .track(descriptor):
            best(matching: descriptor, in: subtitleTracks).map { .track($0.number) }
                ?? subtitlePick(subtitleTracks, audio: audioTrack, preferences: preferences)
        case nil:
            subtitlePick(subtitleTracks, audio: audioTrack, preferences: preferences)
        }
        return TrackSelection(audio: audio?.number, subtitle: subtitle)
    }

    private static func best(matching descriptor: TrackDescriptor, in tracks: [MediaTrack]) -> MediaTrack? {
        tracks.compactMap { track in descriptor.score(track).map { (track, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// The best track in the first preferred language that has one. Within a language:
    /// tagged before title-matched, regular before commentary/description tracks, then file order.
    private static func preferred(in tracks: [MediaTrack], languages: [String]) -> MediaTrack? {
        for language in languages {
            let tagged = tracks.filter { LanguageMatcher.matches($0.language, language) }
            let titled = tracks.filter {
                LanguageMatcher.canonical($0.language) == nil && LanguageMatcher.title($0.title, names: language)
            }
            let candidates = tagged.isEmpty ? titled : tagged
            if let pick = candidates.first(where: { !isSecondary($0) }) ?? candidates.first {
                return pick
            }
        }
        return nil
    }

    /// Commentary, audio description and hearing-impaired tracks are not what people want by default.
    private static func isSecondary(_ track: MediaTrack) -> Bool {
        guard let title = track.title?.lowercased() else { return false }
        return ["commentary", "description", "descriptive", "sdh", "hearing impaired"].contains { title.contains($0) }
    }

    private static func speaks(_ track: MediaTrack?, anyOf languages: [String]) -> Bool {
        guard let track else { return false }
        return languages.contains { language in
            LanguageMatcher.matches(track.language, language)
                || (LanguageMatcher.canonical(track.language) == nil && LanguageMatcher.title(track.title, names: language))
        }
    }

    private static func subtitlePick(
        _ tracks: [MediaTrack],
        audio: MediaTrack?,
        preferences: TrackPreferences
    ) -> TrackSelection.Subtitle? {
        guard !tracks.isEmpty else { return nil }
        let full = tracks.filter { !$0.isForced }
        let understandsAudio = speaks(audio, anyOf: preferences.audioLanguages)

        let wantsFull = switch preferences.subtitleMode {
        case .always: true
        case .automatic: !understandsAudio
        case .off: false
        }
        if wantsFull, let pick = preferred(in: full, languages: preferences.subtitleLanguages) {
            return .track(pick.number)
        }
        // Forced subtitles translate the bits of dialogue that are not in the audio's language.
        if let audio, let forced = tracks.first(where: { $0.isForced && LanguageMatcher.matches($0.language, audio.language) }) {
            return .track(forced.number)
        }
        return .off
    }
}
