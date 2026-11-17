import Foundation

/// A best guess at what a media file is, read from its name:
/// `The.Office.US.S02E05.720p.WEB.x264-GRP.mkv` is "The Office US", season 2, episode 5.
public struct MediaNameGuess: Sendable, Equatable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?

    public init(title: String, year: Int? = nil, season: Int? = nil, episode: Int? = nil) {
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
    }

    public var isEpisode: Bool {
        season != nil && episode != nil
    }

    /// Words that mark the end of the title in release names.
    private static let tags: Set<String> = [
        "480p", "576p", "720p", "1080p", "1080i", "2160p", "4k", "uhd", "bluray", "blu-ray", "brrip", "bdrip", "dvdrip", "dvd",
        "webrip", "web-dl", "webdl", "web", "hdtv", "hdrip", "remux", "x264", "x265", "h264", "h265", "hevc", "avc", "av1",
        "hdr", "hdr10", "dv", "10bit", "proper", "repack", "extended", "unrated", "multi", "dubbed", "subbed",
    ]

    /// - Parameter fileName: A file name, with or without its extension. A path's folders are ignored.
    public init(fileName: String) {
        var name = (fileName as NSString).lastPathComponent
        let fileExtension = (name as NSString).pathExtension
        if !fileExtension.isEmpty, fileExtension.count <= 5, fileExtension.allSatisfy({ $0.isLetter || $0.isNumber }) {
            name = (name as NSString).deletingPathExtension
        }
        // Release groups and notes in brackets say nothing about the title.
        name = name.replacing(/\[[^\]]*\]/, with: " ")
        name = name.replacing(/[._]/, with: " ")

        var title = name
        var season: Int?
        var episode: Int?
        if let match = name.firstMatch(of: /(?i)\bS(\d{1,2})\s*-?\s*E(\d{1,3})\b/) ?? name.firstMatch(of: /(?i)\b(\d{1,2})x(\d{2,3})\b/) {
            season = Int(match.output.1)
            episode = Int(match.output.2)
            title = String(name[..<match.range.lowerBound])
        }

        // The last year-like number is the release year ("Blade Runner 2049 2017"); one that
        // opens the name is part of the title ("2001 A Space Odyssey").
        var year: Int?
        let years = title.matches(of: /\(?\b((?:19|20)\d{2})\b\)?/)
        if let last = years.last, !title[..<last.range.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
            year = Int(last.output.1)
            title = String(title[..<last.range.lowerBound])
        }

        let words = title.split(separator: " ", omittingEmptySubsequences: true)
        let kept = words.prefix { !Self.tags.contains($0.lowercased()) }
        title = kept.joined(separator: " ")
            .replacing(/\([^)]*\)/, with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–("))

        self.init(title: title, year: year, season: season, episode: episode)
    }
}
