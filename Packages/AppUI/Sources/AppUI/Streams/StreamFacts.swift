import Foundation

/// What can be read out of the free text an add-on describes a stream with, beyond quality
/// and size: how many people share it, which languages it speaks, and whether it is one of
/// the kinds of entry that will not play as a stream at all.
///
/// Add-ons write this text however they like. These are the common habits (a person sign
/// before the number of people sharing, flags for languages, scene release words), read
/// leniently: what is not recognised is simply unknown, and the picker treats unknown as neutral.
public struct StreamFacts: Sendable, Equatable {
    /// Why an entry should never be picked automatically.
    public enum Trap: Sendable, Equatable {
        /// A whole disc (folders or an image), not one video file.
        case discImage
        /// Filmed in a cinema.
        case cinemaRecording
        /// Two pictures side by side or stacked, for 3D screens.
        case stereoscopic
        /// A short excerpt.
        case sample

        public var explanation: String {
            switch self {
            case .discImage: "a whole disc, not one video file"
            case .cinemaRecording: "filmed in a cinema"
            case .stereoscopic: "made for 3D screens"
            case .sample: "only a sample"
            }
        }
    }

    /// People sharing a torrent, when the add-on says.
    public var peers: Int?
    /// Languages the sound comes in, as two-letter codes. Empty when the text does not say.
    public var languages: Set<String> = []
    /// Whether the text says it carries several languages without naming them all.
    public var isMultiLanguage = false
    public var trap: Trap?

    public init(peers: Int? = nil, languages: Set<String> = [], isMultiLanguage: Bool = false, trap: Trap? = nil) {
        self.peers = peers
        self.languages = languages
        self.isMultiLanguage = isMultiLanguage
        self.trap = trap
    }

    public init(text: String) {
        peers = Self.peers(in: text)
        (languages, isMultiLanguage) = Self.languages(in: text)
        trap = Self.trap(in: text)
    }

    // MARK: - Reading

    static func peers(in text: String) -> Int? {
        // A person sign, or the word, then the number: "👤 15", "Seeders: 15", "seeds 15".
        let pattern = /(?:👤|👥|🌱|\bseed(?:er)?s?\b\s*[:=]?)\s*(\d{1,7})/.ignoresCase()
        return text.firstMatch(of: pattern).flatMap { Int($0.output.1) }
    }

    /// The country a flag stands for, to the language films from there are dubbed in.
    private static let languageOfCountry: [String: String] = [
        "GB": "en", "US": "en", "AU": "en", "CA": "en", "IE": "en", "NZ": "en",
        "DE": "de", "AT": "de", "CH": "de", "FR": "fr", "BE": "fr", "ES": "es", "MX": "es", "AR": "es", "CL": "es", "CO": "es",
        "IT": "it", "PT": "pt", "BR": "pt", "RU": "ru", "UA": "uk", "JP": "ja", "KR": "ko", "CN": "zh", "TW": "zh", "HK": "zh",
        "IN": "hi", "NL": "nl", "PL": "pl", "CZ": "cs", "SK": "sk", "HU": "hu", "DK": "da", "SE": "sv", "NO": "nb", "FI": "fi",
        "TR": "tr", "SA": "ar", "AE": "ar", "EG": "ar", "IL": "he", "VN": "vi", "ID": "id", "MY": "ms", "TH": "th", "GR": "el",
        "RO": "ro", "BG": "bg", "HR": "hr", "RS": "sr", "SI": "sl", "LT": "lt", "LV": "lv", "EE": "et", "IR": "fa", "PH": "tl",
    ]

    /// Words scene releases use for the language of the sound.
    private static let languageOfWord: [String: String] = [
        "english": "en", "eng": "en", "german": "de", "deutsch": "de", "ger": "de", "french": "fr", "truefrench": "fr",
        "vff": "fr", "vfq": "fr", "vf": "fr", "spanish": "es", "castellano": "es", "latino": "es", "lat": "es", "esp": "es",
        "italian": "it", "ita": "it", "russian": "ru", "rus": "ru", "hindi": "hi", "japanese": "ja", "jap": "ja",
        "korean": "ko", "kor": "ko", "portuguese": "pt", "dublado": "pt", "polish": "pl", "turkish": "tr", "dutch": "nl",
    ]

    static func languages(in text: String) -> (languages: Set<String>, isMulti: Bool) {
        var found = Set<String>()
        // A flag is two "regional indicator" characters spelling a country code.
        var country = ""
        for scalar in text.unicodeScalars {
            if (0x1F1E6 ... 0x1F1FF).contains(scalar.value), let letter = Unicode.Scalar(scalar.value - 0x1F1E6 + 65) {
                country.unicodeScalars.append(letter)
                if country.count == 2 {
                    if let language = languageOfCountry[country] {
                        found.insert(language)
                    }
                    country = ""
                }
            } else {
                country = ""
            }
        }
        let lowered = text.lowercased()
        for word in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let language = languageOfWord[String(word)] {
                found.insert(language)
            }
        }
        // Text in Cyrillic is a Russian release, whatever else it says.
        if text.unicodeScalars.contains(where: { (0x0400 ... 0x04FF).contains($0.value) }) {
            found.insert("ru")
        }
        let isMulti = lowered.contains(/\b(?:multi|dual)\b/.wordBoundaryKind(.simple))
        return (found, isMulti)
    }

    static func trap(in text: String) -> Trap? {
        let lowered = text.lowercased()
        func mentions(_ pattern: Regex<Substring>) -> Bool {
            lowered.contains(pattern.wordBoundaryKind(.simple))
        }
        if mentions(/\bcomplete\b[^\n]{0,24}\b(?:bluray|blu-ray|bd|uhd)\b/) || mentions(/\b(?:bdmv|iso|bd25|bd50|bd66|bd100|dvd5|dvd9|dvdr)\b/)
            || mentions(/\bfull\b[^\n]{0,8}\b(?:bluray|blu-ray|bd|disc)\b/) {
            return .discImage
        }
        if mentions(/\b(?:cam|camrip|hdcam|hdts|telesync|telecine|hdtc)\b/) {
            return .cinemaRecording
        }
        if mentions(/\b(?:3d|sbs|hsbs|hou)\b/) {
            return .stereoscopic
        }
        if mentions(/\bsample\b/) {
            return .sample
        }
        return nil
    }
}

/// How long a title runs, read from what catalogs write: "156 min", "2h 36min", "1 h 5 m".
public enum RuntimeText {
    public static func seconds(in text: String?) -> Double? {
        guard let text = text?.lowercased() else { return nil }
        let hours = text.firstMatch(of: /(\d+)\s*(?:h|hr|hrs|hour|hours)\b/).flatMap { Double($0.output.1) } ?? 0
        let minutes = text.firstMatch(of: /(\d+)\s*(?:m|min|mins|minute|minutes)\b/).flatMap { Double($0.output.1) } ?? 0
        let total = hours * 3600 + minutes * 60
        if total > 0 {
            return total
        }
        // A bare number is minutes.
        if let bare = Double(text.trimmingCharacters(in: .whitespaces)), bare > 0, bare < 1000 {
            return bare * 60
        }
        return nil
    }
}
