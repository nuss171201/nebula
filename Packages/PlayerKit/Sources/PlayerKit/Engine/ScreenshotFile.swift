import CoreGraphics
import Foundation

/// Names screenshots and writes them to disk as PNG.
enum ScreenshotFile {
    enum WriteError: Error, Sendable {
        case cannotEncode
    }

    /// A file name (without extension) made of what is playing and where: `Big Buck Bunny 0.12.34`.
    ///
    /// - Parameters:
    ///   - title: The media's title or file name.
    ///   - isFileName: Whether `title` is a file name, whose extension is then left out.
    static func baseName(title: String, isFileName: Bool, position: Double) -> String {
        let name = isFileName ? (title as NSString).deletingPathExtension : title
        // "/" separates folders and ":" is shown as one by Finder; control characters have no place in a name.
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) ? "-" : scalar
        }))
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let stem = cleaned.isEmpty ? "Screenshot" : String(cleaned.prefix(100))
        return stem + " " + PlaybackTime.format(position).replacingOccurrences(of: ":", with: ".")
    }

    /// The first name that is free: `name.png`, then `name 2.png`, `name 3.png`, …
    static func freeURL(baseName: String, in directory: URL, exists: (URL) -> Bool) -> URL {
        var candidate = directory.appendingPathComponent(baseName + ".png")
        var number = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(baseName) \(number).png")
            number += 1
        }
        return candidate
    }

    /// Writes the image into `directory` (created if needed) without replacing anything.
    static func write(_ image: CGImage, baseName: String, in directory: URL) throws -> URL {
        guard let data = FrameImage.pngData(image) else { throw WriteError.cannotEncode }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = freeURL(baseName: baseName, in: directory) { files.fileExists(atPath: $0.path) }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}
