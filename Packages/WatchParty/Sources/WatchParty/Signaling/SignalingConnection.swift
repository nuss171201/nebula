import Foundation
import os

/// One web-socket connection to the signalling server: frames out in the order they were handed
/// over, frames in, and a ping now and then so that a connection that has died quietly is noticed.
final class SignalingConnection: Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let outbox: AsyncStream<ClientFrame>.Continuation
    private let lastAnswer = OSAllocatedUnfairLock(initialState: ContinuousClock.now)

    init(url: URL, userAgent: String) {
        let configuration = URLSessionConfiguration.ephemeral
        // How long to wait for the server to answer at all; an open socket may stay quiet for longer.
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
        // Introductions are a few kilobytes; anything much larger is not one.
        task.maximumMessageSize = 256 * 1024
        let (frames, outbox) = AsyncStream<ClientFrame>.makeStream()
        self.outbox = outbox
        task.resume()
        Task { [task] in
            for await frame in frames {
                guard let data = try? JSONEncoder().encode(frame), let text = String(data: data, encoding: .utf8) else { continue }
                do {
                    try await task.send(.string(text))
                } catch {
                    // The receiving side reports the failure; nothing more can be sent on this one.
                    break
                }
            }
        }
    }

    /// Sends a frame after the ones already handed over.
    func enqueue(_ frame: ClientFrame) {
        outbox.yield(frame)
    }

    /// The next frame from the server. Frames this version does not know are skipped.
    func receive() async throws -> ServerFrame {
        while true {
            let message = try await task.receive()
            lastAnswer.withLock { $0 = .now }
            let data: Data
            switch message {
            case let .string(text): data = Data(text.utf8)
            case let .data(binary): data = binary
            @unknown default: continue
            }
            if let frame = try? JSONDecoder().decode(ServerFrame.self, from: data) {
                return frame
            }
        }
    }

    /// Asks the server to answer. Closes the connection if it has been silent for too long,
    /// which makes `receive` throw.
    func checkAlive(silenceLimit: Duration) {
        if ContinuousClock.now - lastAnswer.withLock({ $0 }) > silenceLimit {
            close()
            return
        }
        task.sendPing { [lastAnswer] error in
            if error == nil {
                lastAnswer.withLock { $0 = .now }
            }
        }
    }

    func close() {
        outbox.finish()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
