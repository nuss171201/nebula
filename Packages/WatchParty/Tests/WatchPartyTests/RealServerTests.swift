import Foundation
import Testing
@testable import WatchParty

/// The signalling server itself (`Server/signal.ts`), run with Deno on this machine's loopback
/// interface for the length of a test.
final class RealSignalServer: Sendable {
    static let denoPath: String? = {
        let candidates = ["/opt/homebrew/bin/deno", "/usr/local/bin/deno"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/deno" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Server/signal.ts")

    static var isAvailable: Bool {
        denoPath != nil && FileManager.default.fileExists(atPath: script.path)
    }

    let address: URL
    private let process: Process

    init(roomLimit: Int = 8) async throws {
        let port = Int.random(in: 20000 ..< 60000)
        address = try #require(URL(string: "http://127.0.0.1:\(port)/"))
        process = Process()
        process.executableURL = try URL(fileURLWithPath: #require(Self.denoPath))
        process.arguments = ["run", "--no-prompt", "--allow-net=127.0.0.1:\(port)", "--allow-env", Self.script.path]
        process.environment = [
            "PORT": "\(port)", "HOST": "127.0.0.1", "ROOM_LIMIT": "\(roomLimit)", "ICE_SERVERS": "[]",
            "DENO_NO_UPDATE_CHECK": "1", "HOME": NSHomeDirectory(),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Up when it answers.
        let health = address.appendingPathComponent("healthz")
        for _ in 0 ..< 100 {
            if let (data, _) = try? await URLSession.shared.data(from: health), String(data: data, encoding: .utf8) == "ok\n" {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw CocoaError(.fileReadUnknown)
    }

    func stop() {
        process.terminate()
    }
}

@Suite("Against the signalling server itself", .serialized, .enabled(if: RealSignalServer.isAvailable, "Deno is not installed"))
struct RealServerTests {
    @Test("Three apps meet through the server, one drops off the server and comes back, and a full room refuses")
    func meetThroughTheRealServer() async throws {
        let server = try await RealSignalServer(roomLimit: 3)
        defer { server.stop() }
        let invite = try PartyInvite.make(server: #require(PartyServer(server.address.absoluteString)))
        let endpoints = ["alpha", "beta", "gamma"].map { TestEndpoint($0, invite: invite) }
        defer { endpoints.forEach { $0.transport.stop() } }
        await eventually("everyone connected to everyone") { endpoints.allSatisfy { $0.log.connectedPeers.count == 2 } }
        endpoints[2].transport.send(Data("hello".utf8), to: nil)
        await eventually("messages arrive") {
            endpoints[0].log.texts(from: endpoints[2].id) == ["hello"] && endpoints[1].log.texts(from: endpoints[2].id) == ["hello"]
        }

        let fourth = TestEndpoint("delta", invite: invite)
        defer { fourth.transport.stop() }
        await eventually("the fourth is refused") { fourth.log.events.contains(.failed(.roomFull)) }

        // Leaving frees the place.
        endpoints[1].transport.stop()
        await eventually("the others see beta go") { endpoints[0].log.connectedPeers == [endpoints[2].id] }
        let fifth = TestEndpoint("epsilon", invite: invite)
        defer { fifth.transport.stop() }
        await eventually("someone new gets the place") { fifth.log.connectedPeers == [endpoints[0].id, endpoints[2].id] }
    }

    @Test("The server answers a browser with a page that says what the link is, and refuses requests that make no sense")
    func pageAndBadRequests() async throws {
        let server = try await RealSignalServer()
        defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(from: server.address)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("Join Watch Party") == true)

        let socketURL = try #require(PartyServer(server.address.absoluteString)).socketURL
        let connection = SignalingConnection(url: socketURL, userAgent: "tests")
        defer { connection.close() }
        // A room name that is not one.
        connection.enqueue(.join(room: "../../etc/passwd", peer: .random()))
        #expect(try await connection.receive() == .error(code: "bad-request"))
        // Asking to pass something on before being in a room goes nowhere, and a proper join still works.
        connection.enqueue(.relay(to: .random(), data: "x"))
        connection.enqueue(.join(room: String(repeating: "ab", count: 16), peer: .random()))
        #expect(try await connection.receive() == .joined(peers: [], iceServers: []))
    }
}
