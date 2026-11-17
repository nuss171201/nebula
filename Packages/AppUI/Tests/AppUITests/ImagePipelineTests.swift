import AddonTestSupport
@testable import AppUI
import CoreGraphics
import Foundation
import ImageIO
import MediaCore
import Testing
import UniformTypeIdentifiers

@Suite("Image pipeline")
struct ImagePipelineTests {
    /// A solid-colour PNG of the given size.
    private static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ImagePipelineTests-\(UUID().uuidString)")
    }

    private let url = URL(string: "https://images.example.com/poster.png") ?? URL(filePath: "/invalid")

    @Test("Images are downsampled to the requested size, keeping their proportions")
    func downsamples() async throws {
        let http = try StubHTTPClient(data: Self.png(width: 1000, height: 1500))
        let pipeline = ImagePipeline(http: http, directory: nil)
        let image = try await pipeline.image(for: url, maxPixelSize: 300)
        #expect(image.height == 300)
        #expect(image.width == 200)
    }

    @Test("A second request is served from memory without another download")
    func memoryCache() async throws {
        let http = try StubHTTPClient(data: Self.png(width: 400, height: 600))
        let pipeline = ImagePipeline(http: http, directory: nil)
        #expect(pipeline.cachedImage(for: url, maxPixelSize: 200) == nil)

        _ = try await pipeline.image(for: url, maxPixelSize: 200)
        _ = try await pipeline.image(for: url, maxPixelSize: 200)
        #expect(http.requestedURLs.count == 1)
        #expect(pipeline.cachedImage(for: url, maxPixelSize: 200) != nil)
    }

    @Test("Concurrent requests for one image share a single download")
    func deduplicates() async throws {
        let data = try Self.png(width: 400, height: 600)
        let http = StubHTTPClient { _ in
            try? await Task.sleep(for: .milliseconds(80))
            return HTTPResponse(data: data, statusCode: 200)
        }
        let pipeline = ImagePipeline(http: http, directory: nil)
        async let first = pipeline.image(for: url, maxPixelSize: 200)
        async let second = pipeline.image(for: url, maxPixelSize: 200)
        async let third = pipeline.image(for: url, maxPixelSize: 200)
        _ = try await (first, second, third)
        #expect(http.requestedURLs.count == 1)
    }

    @Test("A new pipeline reads the original from disk and can produce another size")
    func diskCache() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try Self.png(width: 800, height: 1200)

        let firstHTTP = StubHTTPClient(data: data)
        _ = try await ImagePipeline(http: firstHTTP, directory: directory).image(for: url, maxPixelSize: 300)
        #expect(firstHTTP.requestedURLs.count == 1)

        let secondHTTP = StubHTTPClient(data: data)
        let second = ImagePipeline(http: secondHTTP, directory: directory)
        let larger = try await second.image(for: url, maxPixelSize: 600)
        #expect(larger.height == 600)
        #expect(secondHTTP.requestedURLs.isEmpty)
        #expect(await second.diskUsage() == data.count)
    }

    @Test("Bytes that are not an image fail and are not written to disk")
    func undecodable() async throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ImagePipeline(http: StubHTTPClient(data: Data("<html>".utf8)), directory: directory)
        await #expect(throws: ImagePipelineError.undecodable) {
            try await pipeline.image(for: url, maxPixelSize: 200)
        }
        #expect(await pipeline.diskUsage() == 0)
    }

    @Test("Download failures are reported and a later attempt can succeed")
    func downloadFailure() async throws {
        let data = try Self.png(width: 100, height: 100)
        let attempts = Counter()
        let http = StubHTTPClient { _ throws(HTTPError) in
            if await attempts.next() == 1 {
                throw .badStatus(404)
            }
            return HTTPResponse(data: data, statusCode: 200)
        }
        let pipeline = ImagePipeline(http: http, directory: nil)
        await #expect(throws: ImagePipelineError.download(.badStatus(404))) {
            try await pipeline.image(for: url, maxPixelSize: 50)
        }
        let image = try await pipeline.image(for: url, maxPixelSize: 50)
        #expect(image.width == 50)
    }

    @Test("Plain-HTTP artwork is fetched over HTTPS, except from this machine", arguments: [
        ("http://images.example.com/a.png", "https://images.example.com/a.png"),
        ("https://images.example.com/a.png", "https://images.example.com/a.png"),
        ("http://127.0.0.1:7000/a.png", "http://127.0.0.1:7000/a.png"),
        ("http://localhost:7000/a.png", "http://localhost:7000/a.png"),
    ])
    func httpsUpgrade(input: String, expected: String) throws {
        let url = try #require(URL(string: input))
        #expect(ImagePipeline.secureURL(for: url).absoluteString == expected)
    }

    @Test("Trimming removes the least recently used files once over budget")
    func trim() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageDiskCache(directory: directory, limit: 2500)
        let urls = try (1 ... 4).map { try #require(URL(string: "https://images.example.com/\($0).png")) }

        // Give each file a distinct, increasing date so the first is the least recently used.
        for (index, url) in urls.enumerated() {
            cache.store(Data(repeating: 0, count: 1000), for: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))],
                ofItemAtPath: directory.appendingPathComponent(ImageDiskCache.fileName(for: url)).path
            )
        }

        #expect(cache.totalSize() == 4000)
        cache.trim()
        #expect(cache.totalSize() == 2000)
        #expect(cache.data(for: urls[0]) == nil)
        #expect(cache.data(for: urls[1]) == nil)
        #expect(cache.data(for: urls[2]) != nil)
        #expect(cache.data(for: urls[3]) != nil)

        cache.removeAll()
        #expect(cache.totalSize() == 0)
    }
}

private actor Counter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}
