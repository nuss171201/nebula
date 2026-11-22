import Foundation
import Testing
@testable import WatchParty

@Suite("The party server inside the app")
struct PartyHostServerTests {
    @Test("With a fixed port, the port after it answers a browser with a page that says the server can be reached")
    func checkPage() async throws {
        // A port of the test's own choosing may be taken; another is tried then.
        for _ in 0 ..< 5 {
            let port = UInt16.random(in: 20000 ..< 60000)
            let server = try PartyHostServer(reach: .thisMac, port: port)
            guard let address = try? await server.start(), let check = server.checkAddress else {
                server.stop()
                continue
            }
            defer { server.stop() }
            #expect(address.port == Int(port))
            #expect(check.absoluteString == "http://127.0.0.1:\(port + 1)/")
            let (data, response) = try await URLSession(configuration: .ephemeral).data(from: check)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/html; charset=utf-8")
            #expect(String(bytes: data, encoding: .utf8)?.contains("The party server is running") == true)
            return
        }
        Issue.record("no free pair of ports in five tries")
    }

    @Test("A server on any free port has no check page: there would be no saying where it is")
    func noFixedPort() async throws {
        let server = try PartyHostServer(reach: .thisMac)
        defer { server.stop() }
        _ = try await server.start()
        #expect(server.checkAddress == nil)
        let zero = try PartyHostServer(reach: .thisMac, port: 0)
        defer { zero.stop() }
        _ = try await zero.start()
        #expect(zero.checkAddress == nil)
    }

    @Test("The page is a whole answer: a status line, its length, and the body")
    func response() throws {
        let text = try #require(String(bytes: PartyReachPage.response, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: \(PartyReachPage.body.utf8.count)\r\n"))
        #expect(text.hasSuffix(PartyReachPage.body))
    }
}
