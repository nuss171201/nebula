import Foundation
import Network
import os

/// A plain web page beside the party server, for finding out with a browser whether another
/// device can reach this Mac at all.
///
/// The party server itself speaks WebSocket only, and hangs up on a browser without a word,
/// which reads as a fault. When a party will not connect there are three places it can stop
/// (the network between the devices, macOS on this Mac, macOS on the other), and from inside
/// either app they look alike. A browser on the other device is under none of the app's
/// restrictions there, so this page answers the first question by itself.
final class PartyReachPage: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "PartyReachPage")
    private let logger: Logger?

    /// - Parameter host: The address to listen on, which is the party server's.
    init(host: NWEndpoint.Host, port: UInt16, logger: Logger?) throws {
        self.logger = logger
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    deinit {
        listener.cancel()
    }

    /// Starts serving. `false` if the port could not be had (something else is using it).
    func start() async -> Bool {
        listener.newConnectionHandler = { [queue, logger] connection in
            logger?.notice("the check page was asked for from \(PartyHostServer.describe(connection.endpoint), privacy: .public)")
            connection.start(queue: queue)
            // Whatever is asked for gets the one page; the request only has to have begun.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: Self.response, completion: .contentProcessed { _ in connection.cancel() })
            }
            // Someone who connects and says nothing is not kept.
            queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
        }
        let didAnswer = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { [logger] update in
                let isServing: Bool
                switch update {
                case .ready:
                    isServing = true
                case let .failed(error):
                    logger?.error("the check page could not be served: \(String(describing: error), privacy: .public)")
                    isServing = false
                case .cancelled:
                    isServing = false
                default:
                    return
                }
                let isFirst = didAnswer.withLock { answered in
                    defer { answered = true }
                    return !answered
                }
                if isFirst {
                    continuation.resume(returning: isServing)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    static let body = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Party server</title></head>
    <body style="font: 17px -apple-system, sans-serif; margin: 3em auto; max-width: 30em; padding: 0 1em">
    <h1 style="font-size: 1.4em">The party server is running</h1>
    <p>This device can reach it. If a watch party still does not connect from here, the app on this
    device is not being let onto the local network: on a Mac, see System Settings, Privacy &amp; Security,
    Local Network.</p></body></html>
    """

    static var response: Data {
        let body = Data(body.utf8)
        let head = [
            "HTTP/1.1 200 OK", "Content-Type: text/html; charset=utf-8", "Content-Length: \(body.count)",
            "Cache-Control: no-store", "Connection: close", "", "",
        ].joined(separator: "\r\n")
        return Data(head.utf8) + body
    }
}
