import Foundation

/// How tracks are described to the user.
public extension MediaTrack {
    /// Familiar names for codec identifiers; unknown ones are shown in capitals.
    static func codecName(_ codec: String?) -> String? {
        guard let codec, !codec.isEmpty else { return nil }
        let known: [String: String] = [
            "ac3": "AC-3", "eac3": "E-AC-3", "dts": "DTS", "truehd": "TrueHD", "aac": "AAC", "mp3": "MP3", "flac": "FLAC",
            "opus": "Opus", "vorbis": "Vorbis", "alac": "ALAC", "pcm_s16le": "PCM", "pcm_s24le": "PCM", "mp2": "MP2",
            "h264": "H.264", "hevc": "HEVC", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "mpeg2video": "MPEG-2", "mpeg4": "MPEG-4",
            "subrip": "SRT", "ass": "ASS", "ssa": "SSA", "webvtt": "WebVTT", "hdmv_pgs_subtitle": "PGS", "dvd_subtitle": "VobSub",
            "mov_text": "Text", "dvb_subtitle": "DVB",
        ]
        return known[codec.lowercased()] ?? codec.uppercased()
    }

    /// "Mono", "Stereo", "5.1", "7.1", or "N channels".
    static func channelLayoutName(_ count: Int?) -> String? {
        switch count {
        case nil, 0?: nil
        case 1?: "Mono"
        case 2?: "Stereo"
        case 6?: "5.1"
        case 8?: "7.1"
        case let other?: "\(other) channels"
        }
    }

    /// The main line: the language if tagged, with the title where it adds something;
    /// otherwise the title, otherwise "Track N".
    func displayName(locale: Locale = .current) -> String {
        let language = LanguageMatcher.displayName(for: language, locale: locale)
        switch (language, title) {
        case let (language?, title?) where title.caseInsensitiveCompare(language) != .orderedSame
            && !LanguageMatcher.title(title, names: self.language ?? ""):
            return "\(language) — \(title)"
        case let (language?, _):
            return language
        case let (nil, title?):
            return title
        case (nil, nil):
            return "Track \(number)"
        }
    }

    /// The small print: codec, layout or size, and flags.
    var detail: String {
        var parts: [String] = []
        if let codec = Self.codecName(codec) {
            parts.append(codec)
        }
        switch kind {
        case .audio:
            if let layout = Self.channelLayoutName(channelCount) {
                parts.append(layout)
            }
        case .video:
            if let width, let height {
                parts.append("\(width)×\(height)")
            }
            if let framesPerSecond, framesPerSecond > 0 {
                parts.append(String(format: "%g fps", (framesPerSecond * 100).rounded() / 100))
            }
        case .subtitle:
            break
        }
        if isForced {
            parts.append("Forced")
        }
        if isExternal {
            parts.append("External")
        }
        if isDefault {
            parts.append("Default")
        }
        return parts.joined(separator: " · ")
    }
}

public extension PlaybackSpeed {
    /// Speeds offered in menus.
    static let menuChoices: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 8, 16]
}

/// Formats a delay in seconds for display: "0 s", "+0.25 s", "−1.5 s".
public func formattedDelay(_ seconds: Double) -> String {
    let rounded = (seconds * 1000).rounded() / 1000
    if rounded == 0 {
        return "0 s"
    }
    let magnitude = String(format: "%g", abs(rounded))
    return (rounded > 0 ? "+" : "−") + magnitude + " s"
}
