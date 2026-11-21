import Foundation
import TorrentBridge

/// What the engine does when the session reports something, and the bookkeeping for
/// everything that is waiting on a torrent.
extension TorrentEngine {
    func handle(_ event: TorrentEvent) {
        switch event {
        case let .metadata(infoHash):
            refreshMetadata(of: infoHash)

        case let .pieceFinished(infoHash, piece):
            guard torrents[infoHash] != nil else { return }
            torrents[infoHash]?.completed.insert(piece)
            torrents[infoHash]?.arrivals.append(piece)
            if let count = torrents[infoHash]?.arrivals.count, count > 600 {
                torrents[infoHash]?.arrivals.removeFirst(count - 400)
            }
            for index in torrents[infoHash]?.streams.keys.map(\.self) ?? [] {
                torrents[infoHash]?.streams[index]?.plan.deadlines[piece] = nil
                torrents[infoHash]?.streams[index]?.plan.priorities[piece] = nil
            }
            for waiter in torrents[infoHash]?.pieceWaiters.removeValue(forKey: piece) ?? [] {
                waiter.continuation.resume()
            }

        case let .pieceRead(infoHash, piece, data, message):
            let waiters = torrents[infoHash]?.readWaiters.removeValue(forKey: piece) ?? []
            if let data {
                remember(piece: piece, data: data, of: infoHash)
                waiters.forEach { $0.continuation.resume(returning: data) }
            } else {
                waiters.forEach { $0.continuation.resume(throwing: TorrentError.failed(message ?? "A piece could not be read.")) }
            }

        case let .fileChoiceApplied(infoHash):
            // libtorrent has just set every piece back to its file's priority: what it was told
            // before is gone, so it is told everything again, not only what changed.
            for index in torrents[infoHash]?.streams.keys.map(\.self) ?? [] {
                torrents[infoHash]?.streams[index]?.plan = PiecePlan()
                replan(file: index, of: infoHash)
            }

        case let .log(line):
            logger.info("\(line, privacy: .public)")
            onDiagnostic?(line)

        case let .failed(infoHash, message):
            guard var torrent = torrents[infoHash] else { return }
            logger.error("torrent \(infoHash, privacy: .public) failed: \(message, privacy: .public)")
            torrent.failure = message
            let waiting = torrent
            torrent.metadataWaiters = []
            torrent.pieceWaiters = [:]
            torrent.readWaiters = [:]
            torrents[infoHash] = torrent
            fail(waiting, with: TorrentError.failed(message))
        }
    }

    func refreshMetadata(of infoHash: String) {
        guard let torrent = torrents[infoHash], torrent.info == nil, let bridged = session.info(forTorrent: infoHash) else { return }
        let took = (ContinuousClock.now - torrent.addedAt) / .seconds(1)
        logger.notice("""
        \(infoHash.prefix(8), privacy: .public): description after \(String(format: "%.1f", took), privacy: .public) s, \
        pieces of \(bridged.pieceLength / 1024, privacy: .public) KiB
        """)
        let info = TorrentInfo(
            name: bridged.name,
            pieceLength: bridged.pieceLength,
            pieceCount: bridged.pieceCount,
            totalSize: bridged.totalSize,
            files: bridged.files.map { TorrentFile(index: $0.index, path: $0.path, size: $0.size, offset: $0.offset) }
        )
        torrents[infoHash]?.info = info
        for waiter in torrents[infoHash]?.metadataWaiters ?? [] {
            waiter.continuation.resume(returning: info)
        }
        torrents[infoHash]?.metadataWaiters = []
    }

    func remember(piece: Int, data: Data, of infoHash: String) {
        guard var cached = torrents[infoHash]?.cachedPieces else { return }
        cached.removeAll { $0.piece == piece }
        cached.append((piece, data))
        while cached.count > 1, cached.reduce(0, { $0 + $1.data.count }) > Self.pieceCacheBytes {
            cached.removeFirst()
        }
        torrents[infoHash]?.cachedPieces = cached
    }

    func fail(_ torrent: Torrent, with error: any Error) {
        torrent.metadataWaiters.forEach { $0.continuation.resume(throwing: error) }
        torrent.pieceWaiters.values.joined().forEach { $0.continuation.resume(throwing: error) }
        torrent.readWaiters.values.joined().forEach { $0.continuation.resume(throwing: error) }
    }

    func resumeMetadataWaiter(_ id: UUID, of infoHash: String, with result: Result<TorrentInfo, any Error>) {
        guard let index = torrents[infoHash]?.metadataWaiters.firstIndex(where: { $0.id == id }),
              let waiter = torrents[infoHash]?.metadataWaiters.remove(at: index)
        else { return }
        waiter.continuation.resume(with: result)
    }

    func cancelPieceWaiter(_ id: UUID, piece: Int, of infoHash: String) {
        guard let index = torrents[infoHash]?.pieceWaiters[piece]?.firstIndex(where: { $0.id == id }),
              let waiter = torrents[infoHash]?.pieceWaiters[piece]?.remove(at: index)
        else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func cancelReadWaiter(_ id: UUID, piece: Int, of infoHash: String) {
        guard let index = torrents[infoHash]?.readWaiters[piece]?.firstIndex(where: { $0.id == id }),
              let waiter = torrents[infoHash]?.readWaiters[piece]?.remove(at: index)
        else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}
