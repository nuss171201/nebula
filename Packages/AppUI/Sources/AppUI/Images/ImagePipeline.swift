import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MediaCore

public enum ImagePipelineError: Error, Sendable, Equatable {
    case download(HTTPError)
    /// The bytes are not an image ImageIO can decode.
    case undecodable
    case tooLarge
}

/// Loads remote artwork: downloads once, keeps the original bytes on disk, and hands
/// the UI images already decoded and downsampled to the size they are shown at.
///
/// All decoding happens off the main thread, so scrolling never waits on an image.
public actor ImagePipeline {
    /// Largest download accepted for a single image.
    private static let maximumDownloadBytes = 24 * 1024 * 1024

    private let http: any HTTPClient
    private let disk: ImageDiskCache?
    private let memory: ImageMemoryCache
    private var inFlight: [CacheKey: Task<CGImage, any Error>] = [:]

    /// - Parameters:
    ///   - http: Client used for downloads (brings timeout, retry and cancellation).
    ///   - directory: Folder for the disk cache; `nil` disables it.
    ///   - memoryLimit: Budget, in bytes of decoded pixels, for the in-memory cache.
    ///   - diskLimit: Budget, in bytes, for the disk cache.
    public init(
        http: any HTTPClient,
        directory: URL?,
        memoryLimit: Int = 160 * 1024 * 1024,
        diskLimit: Int = 512 * 1024 * 1024
    ) {
        self.http = http
        disk = directory.map { ImageDiskCache(directory: $0, limit: diskLimit) }
        memory = ImageMemoryCache(limit: memoryLimit)
    }

    /// An image whose longest edge is at most `maxPixelSize` pixels.
    public func image(for url: URL, maxPixelSize: Int) async throws -> CGImage {
        let key = CacheKey(url: url, maxPixelSize: maxPixelSize)
        if let cached = memory.image(for: key) {
            return cached
        }
        if let running = inFlight[key] {
            return try await running.value
        }

        let task = Task.detached(priority: .userInitiated) { [http, disk] in
            try await Self.load(url, maxPixelSize: maxPixelSize, http: http, disk: disk)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let image = try await task.value
        memory.insert(image, for: key)
        return image
    }

    /// The image if it is already decoded in memory. Safe to call from any thread;
    /// lets a view show a cached image without a placeholder frame.
    public nonisolated func cachedImage(for url: URL, maxPixelSize: Int) -> CGImage? {
        memory.image(for: CacheKey(url: url, maxPixelSize: maxPixelSize))
    }

    /// Deletes least-recently-used files until the disk cache is within its budget.
    public func trimDiskCache() async {
        guard let disk else { return }
        await Task.detached(priority: .utility) { disk.trim() }.value
    }

    /// Bytes currently used by the disk cache.
    public func diskUsage() async -> Int {
        guard let disk else { return 0 }
        return await Task.detached(priority: .utility) { disk.totalSize() }.value
    }

    public func removeAll() async {
        memory.removeAll()
        guard let disk else { return }
        await Task.detached(priority: .utility) { disk.removeAll() }.value
    }

    private static func load(
        _ url: URL,
        maxPixelSize: Int,
        http: any HTTPClient,
        disk: ImageDiskCache?
    ) async throws -> CGImage {
        if let stored = disk?.data(for: url), let image = ImageDownsampler.downsample(stored, maxPixelSize: maxPixelSize) {
            return image
        }

        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: secureURL(for: url), timeout: .seconds(20)))
        } catch {
            throw ImagePipelineError.download(error)
        }
        guard response.data.count <= maximumDownloadBytes else { throw ImagePipelineError.tooLarge }
        guard let image = ImageDownsampler.downsample(response.data, maxPixelSize: maxPixelSize) else {
            throw ImagePipelineError.undecodable
        }
        disk?.store(response.data, for: url)
        return image
    }

    /// Plain-HTTP artwork links are fetched over HTTPS; App Transport Security would
    /// refuse them otherwise. Loopback hosts (local add-ons) are left alone.
    static func secureURL(for url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              host != "localhost", host != "127.0.0.1", host != "::1",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        return components.url ?? url
    }
}

struct CacheKey: Hashable, Sendable {
    let url: URL
    let maxPixelSize: Int

    var memoryKey: NSString {
        "\(maxPixelSize)|\(url.absoluteString)" as NSString
    }
}

enum ImageDownsampler {
    /// Decodes straight to the target size; the full-size bitmap is never materialised.
    static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}

/// Decoded images, evicted by the system under memory pressure or when over budget.
final class ImageMemoryCache: @unchecked Sendable {
    /// NSCache is documented as thread-safe; this wrapper adds no state of its own.
    private let cache = NSCache<NSString, ImageBox>()

    private final class ImageBox {
        let image: CGImage
        init(_ image: CGImage) {
            self.image = image
        }
    }

    init(limit: Int) {
        cache.totalCostLimit = limit
    }

    func image(for key: CacheKey) -> CGImage? {
        cache.object(forKey: key.memoryKey)?.image
    }

    func insert(_ image: CGImage, for key: CacheKey) {
        cache.setObject(ImageBox(image), forKey: key.memoryKey, cost: image.bytesPerRow * image.height)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// Original image bytes on disk, one file per URL, trimmed least-recently-used first.
struct ImageDiskCache: Sendable {
    let directory: URL
    let limit: Int

    init(directory: URL, limit: Int) {
        self.directory = directory
        self.limit = limit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The file name an image URL is stored under: the SHA-256 of the URL, in hex.
    static func fileName(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for url: URL) -> URL {
        directory.appendingPathComponent(Self.fileName(for: url), isDirectory: false)
    }

    func data(for url: URL) -> Data? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        // Reading counts as use: bump the date the trim pass sorts by.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    func store(_ data: Data, for url: URL) {
        try? data.write(to: fileURL(for: url), options: .atomic)
    }

    private func entries() -> [(url: URL, size: Int, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        )) ?? []
        return files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { return nil }
            return (file, size, values.contentModificationDate ?? .distantPast)
        }
    }

    func totalSize() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Brings the cache down to 80 % of its budget once it exceeds the budget.
    func trim() {
        var remaining = entries()
        var total = remaining.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        let target = limit / 5 * 4
        remaining.sort { $0.modified < $1.modified }
        for entry in remaining where total > target {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    func removeAll() {
        for entry in entries() {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}
