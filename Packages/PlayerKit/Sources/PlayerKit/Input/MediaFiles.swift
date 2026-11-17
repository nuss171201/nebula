import Foundation

/// Telling media and subtitle files apart by their names, and finding the media in folders.
public enum MediaFiles {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "mpg", "mpeg", "wmv", "flv", "ogv", "3gp", "vob", "rmvb", "divx",
    ]
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "oga", "opus", "mka", "wma", "ac3", "eac3", "dts", "alac", "ape", "wv",
    ]
    /// Formats the engine reads as subtitles.
    public static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "lrc", "ttml", "mks"]

    public static func isPlayable(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return videoExtensions.contains(fileExtension) || audioExtensions.contains(fileExtension)
    }

    public static func isSubtitle(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    /// What a set of opened or dropped items comes to.
    public struct Selection: Sendable, Equatable {
        /// Files to play, in order.
        public var media: [URL]
        /// Subtitle files that were given directly (not ones found inside folders).
        public var subtitles: [URL]
    }

    /// Sorts out files and folders the user opened or dropped: folders are searched for media
    /// (including their subfolders, skipping hidden files and bundles), each folder's files in
    /// the order Finder would show them; files given directly keep the order they came in.
    ///
    /// - Parameter limit: The most media files to return; a folder tree can hold any number.
    public static func selection(from urls: [URL], limit: Int = 2000, fileManager: FileManager = .default) -> Selection {
        var media: [URL] = []
        var subtitles: [URL] = []
        for url in urls where media.count < limit {
            var isDirectory: ObjCBool = false
            guard url.isFileURL, fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                media += playableFiles(inFolder: url, limit: limit - media.count, fileManager: fileManager)
            } else if isSubtitle(url) {
                subtitles.append(url)
            } else if isPlayable(url) {
                media.append(url)
            }
        }
        return Selection(media: media, subtitles: subtitles)
    }

    /// A folder's own media first, then each subfolder's, every level in the order Finder
    /// shows names in ("Episode 2" before "Episode 10").
    static func playableFiles(inFolder folder: URL, limit: Int, fileManager: FileManager, depth: Int = 0) -> [URL] {
        // Deeper than any real library; a guard against folder structures that loop.
        guard limit > 0, depth < 12 else { return [] }
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var folders: [URL] = []
        var found: [URL] = []
        for item in sorted {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true {
                // An app or a library bundle is a folder only in name.
                if values?.isPackage != true {
                    folders.append(item)
                }
            } else if isPlayable(item) {
                found.append(item)
            }
        }
        found = Array(found.prefix(limit))
        for subfolder in folders where found.count < limit {
            found += playableFiles(inFolder: subfolder, limit: limit - found.count, fileManager: fileManager, depth: depth + 1)
        }
        return found
    }
}
