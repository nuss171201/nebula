import Foundation
import os
@testable import StreamEngine
import Testing

/// A source that never has anything, and records who stopped waiting for it.
private final class StalledSource: ByteSource {
    let size: Int64 = 1 << 20
    let closedReaders = OSAllocatedUnfairLock(initialState: [UUID]())
    let waiting = OSAllocatedUnfairLock(initialState: 0)

    func read(at _: Int64, maxLength _: Int, reader _: UUID) async throws -> Data {
        waiting.withLock { $0 += 1 }
        try await Task.sleep(for: .seconds(60))
        return Data()
    }

    func close(reader: UUID) async {
        closedReaders.withLock { $0.append(reader) }
    }
}

@Suite("HTTP requests and responses (pure)")
struct HTTPMessageTests {
    @Test("A request head is read into method, path and lower-cased headers")
    func parsing() throws {
        let text = "GET /0123456789abcdef0123456789abcdef/My%20Film.mkv?x=1 HTTP/1.1\r\nHost: 127.0.0.1:5000\r\nRange: bytes=10-\r\nUser-Agent: test"
        let head = try #require(HTTPRequestHead.parse(Data(text.utf8)))
        #expect(head.method == "GET")
        #expect(head.path == "/0123456789abcdef0123456789abcdef/My%20Film.mkv")
        #expect(head.headers["range"] == "bytes=10-")
        #expect(head.headers["user-agent"] == "test")
        #expect(StreamServer.token(inPath: head.path) == "0123456789abcdef0123456789abcdef")
    }

    @Test("Anything that is not an HTTP/1.x request for a path is refused", arguments: [
        "", "GET", "GET / HTTP/2", "GET http://example.com/ HTTP/1.1", "GET / HTTP/1.1\r\nno-colon-here", "\r\n",
    ])
    func rejects(text: String) {
        #expect(HTTPRequestHead.parse(Data(text.utf8)) == nil)
    }

    @Test("Only requests addressed to this machine's loopback names are served")
    func hostCheck() {
        func request(host: String?) -> HTTPRequestHead {
            HTTPRequestHead(method: "GET", path: "/", headers: host.map { ["host": $0] } ?? [:])
        }
        #expect(request(host: "127.0.0.1:5000").isAddressedToLoopback(port: 5000))
        #expect(request(host: "LOCALHOST:5000").isAddressedToLoopback(port: 5000))
        #expect(!request(host: "127.0.0.1:5001").isAddressedToLoopback(port: 5000))
        // A page on another site whose name has been pointed at 127.0.0.1.
        #expect(!request(host: "evil.example.com:5000").isAddressedToLoopback(port: 5000))
        #expect(!request(host: nil).isAddressedToLoopback(port: 5000))
    }

    @Test("Tokens are 32 hexadecimal characters followed by one name")
    func tokens() {
        #expect(StreamServer.token(inPath: "/0123456789abcdef0123456789abcdef/a.mkv") != nil)
        #expect(StreamServer.token(inPath: "/short/a.mkv") == nil)
        #expect(StreamServer.token(inPath: "/0123456789abcdef0123456789abcdef") == nil)
        #expect(StreamServer.token(inPath: "/0123456789abcdef0123456789abcdef/a/b.mkv") == nil)
        #expect(StreamServer.token(inPath: "/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/a.mkv") == nil)
    }

    @Test("A resource is answered whole, in part, or not at all, with the headers a player needs")
    func responses() {
        let whole = HTTPResponseHead.forResource(size: 1000, contentType: "video/mp4", rangeHeader: nil)
        #expect(whole.head.status == 200 && whole.body == 0 ... 999)
        #expect(whole.head.headers.contains { $0.name == "Content-Length" && $0.value == "1000" })
        #expect(whole.head.headers.contains { $0.name == "Accept-Ranges" && $0.value == "bytes" })

        let part = HTTPResponseHead.forResource(size: 1000, contentType: "video/mp4", rangeHeader: "bytes=900-")
        #expect(part.head.status == 206 && part.body == 900 ... 999)
        #expect(part.head.headers.contains { $0.name == "Content-Range" && $0.value == "bytes 900-999/1000" })
        #expect(part.head.headers.contains { $0.name == "Content-Length" && $0.value == "100" })

        let beyond = HTTPResponseHead.forResource(size: 1000, contentType: "video/mp4", rangeHeader: "bytes=1000-")
        #expect(beyond.head.status == 416 && beyond.body == nil)
        #expect(beyond.head.headers.contains { $0.name == "Content-Range" && $0.value == "bytes */1000" })

        let empty = HTTPResponseHead.forResource(size: 0, contentType: "video/mp4", rangeHeader: nil)
        #expect(empty.head.status == 200 && empty.body == nil)
        let text = String(bytes: part.head.serialized, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("HTTP/1.1 206 Partial Content\r\n") && text.hasSuffix("\r\n\r\n"))
    }

    @Test("Content types follow the file's extension")
    func contentTypes() {
        #expect(StreamContentType.forFile(named: "Film.MKV") == "video/x-matroska")
        #expect(StreamContentType.forFile(named: "a.mp4") == "video/mp4")
        #expect(StreamContentType.forFile(named: "unknown.xyz") == "application/octet-stream")
    }
}

@Suite("Stream server over loopback", .serialized)
struct StreamServerTests {
    private struct Fixture {
        let server: StreamServer
        let contents: Data
        let url: URL
        let file: URL
    }

    private func makeFixture(size: Int = 700_000) async throws -> Fixture {
        var bytes = [UInt8](repeating: 0, count: size)
        for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index / 251)
        }
        let contents = Data(bytes)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("served-\(UUID().uuidString).mp4")
        try contents.write(to: file)
        let server = StreamServer()
        try await server.start()
        let source = try #require(FileByteSource(url: file))
        let url = try await server.publish(source, named: "My Film.mp4")
        return Fixture(server: server, contents: contents, url: url, file: file)
    }

    private func fetch(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return try (data, #require(response as? HTTPURLResponse))
    }

    @Test("Addresses are on the loopback interface, carry a token, and end in the file's name")
    func addresses() async throws {
        let fixture = try await makeFixture(size: 1000)
        defer {
            Task { await fixture.server.stop() }
            try? FileManager.default.removeItem(at: fixture.file)
        }
        #expect(fixture.url.scheme == "http" && fixture.url.host == "127.0.0.1")
        #expect(await fixture.url.port == (fixture.server.port))
        #expect(fixture.url.lastPathComponent == "My Film.mp4")
        #expect(StreamServer.token(inPath: fixture.url.path) != nil)
        // Starting again changes nothing.
        #expect(try await fixture.server.start() == fixture.url.port)
    }

    @Test("Serves the whole file, any range of it, and its headers alone")
    func serves() async throws {
        let fixture = try await makeFixture()
        defer {
            Task { await fixture.server.stop() }
            try? FileManager.default.removeItem(at: fixture.file)
        }
        let (whole, wholeResponse) = try await fetch(fixture.url)
        #expect(wholeResponse.statusCode == 200)
        #expect(whole == fixture.contents)
        #expect(wholeResponse.value(forHTTPHeaderField: "Content-Type") == "video/mp4")
        #expect(wholeResponse.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")

        let (middle, middleResponse) = try await fetch(fixture.url, range: "bytes=300000-555554")
        #expect(middleResponse.statusCode == 206)
        #expect(middle == fixture.contents.subdata(in: 300_000 ..< 555_555))
        #expect(middleResponse.value(forHTTPHeaderField: "Content-Range") == "bytes 300000-555554/700000")

        let (tail, tailResponse) = try await fetch(fixture.url, range: "bytes=-1000")
        #expect(tailResponse.statusCode == 206 && tail == fixture.contents.suffix(1000))

        let (headBody, headResponse) = try await fetch(fixture.url, method: "HEAD")
        #expect(headResponse.statusCode == 200 && headBody.isEmpty)
        #expect(headResponse.value(forHTTPHeaderField: "Content-Length") == "700000")
    }

    @Test("Refuses ranges past the end, unknown addresses, other methods and withdrawn addresses")
    func refuses() async throws {
        let fixture = try await makeFixture(size: 5000)
        defer {
            Task { await fixture.server.stop() }
            try? FileManager.default.removeItem(at: fixture.file)
        }
        #expect(try await fetch(fixture.url, range: "bytes=5000-").1.statusCode == 416)
        // A guessed token.
        let guessed = try #require(URL(string: "http://127.0.0.1:\(fixture.url.port ?? 0)/\(String(repeating: "0", count: 32))/My%20Film.mp4"))
        #expect(try await fetch(guessed).1.statusCode == 404)
        #expect(try await fetch(fixture.url.deletingLastPathComponent()).1.statusCode == 404)
        #expect(try await fetch(fixture.url, method: "POST").1.statusCode == 405)
        #expect(try await fetch(fixture.url, method: "DELETE").1.statusCode == 405)

        await fixture.server.withdraw(fixture.url)
        #expect(try await fetch(fixture.url).1.statusCode == 404)
    }

    @Test("When the player hangs up while waiting for data, the source is told at once")
    func noticesDisconnect() async throws {
        let server = StreamServer()
        try await server.start()
        defer { Task { await server.stop() } }
        let source = StalledSource()
        let url = try await server.publish(source, named: "stalled.mkv")

        let request = Task { try await fetch(url) }
        // The head arrives; the body never does.
        for _ in 0 ..< 200 where source.waiting.withLock({ $0 }) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(source.waiting.withLock { $0 } == 1)
        #expect(await server.activeConnectionCount == 1)
        request.cancel()
        _ = try? await request.value

        for _ in 0 ..< 300 where source.closedReaders.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(source.closedReaders.withLock { $0.count } == 1)
        for _ in 0 ..< 200 where await server.activeConnectionCount != 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await server.activeConnectionCount == 0)
    }

    @Test("A file inside a torrent that is still arriving is served like any other")
    func servesTorrent() async throws {
        let swarm = try await LoopbackSwarm.make(size: 2 << 20, fileName: "clip.mkv")
        let server = StreamServer()
        try await server.start()
        defer {
            Task {
                await server.stop()
                await swarm.tearDown()
            }
        }
        try await swarm.connect()
        let info = try await swarm.leecher.metadata(of: swarm.infoHash, timeout: .seconds(20))
        let map = try await swarm.leecher.open(file: 0, of: swarm.infoHash)
        let source = TorrentByteSource(engine: swarm.leecher, infoHash: swarm.infoHash, fileIndex: 0, size: map.fileSize)
        let url = try await server.publish(source, named: info.files[0].name)

        // As a player would: the end first, then from the start.
        let (tail, tailResponse) = try await fetch(url, range: "bytes=\((2 << 20) - 4096)-")
        #expect(tailResponse.statusCode == 206 && tail == swarm.contents.suffix(4096))
        let (whole, wholeResponse) = try await fetch(url)
        #expect(wholeResponse.statusCode == 200 && whole == swarm.contents)
        #expect(wholeResponse.value(forHTTPHeaderField: "Content-Type") == "video/x-matroska")
    }
}
