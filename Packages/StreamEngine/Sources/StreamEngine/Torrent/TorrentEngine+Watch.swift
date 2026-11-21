import Foundation
import TorrentBridge

/// Looking for people sharing a torrent, and keeping an eye on what is being waited for.
extension TorrentEngine {
    /// Seconds after a torrent is added at which the hash table is asked for people sharing
    /// it, until its description has arrived. The engine is usually started for the very
    /// torrent it is then given, and libtorrent asks by itself only for torrents added once the
    /// table is running; left alone, the first torrent of a session found nobody (measured: no
    /// peer in 90 seconds for a torrent with thousands). Asking costs a few small packets.
    static let peerSearchSchedule: [Double] = [0, 1, 2, 4, 7, 11, 16, 22, 30, 40, 55]

    func lookForPeers(of infoHash: String) {
        Task { [weak self] in
            var elapsed = 0.0
            for moment in Self.peerSearchSchedule {
                try? await Task.sleep(for: .seconds(moment - elapsed))
                elapsed = moment
                guard await self?.askHashTable(about: infoHash) == true else { return }
            }
        }
    }

    /// Returns whether it is worth asking again later.
    func askHashTable(about infoHash: String) -> Bool {
        guard !isShutDown, let torrent = torrents[infoHash], torrent.info == nil else { return false }
        session.lookForPeers(ofTorrent: infoHash)
        return true
    }

    // MARK: - Watching what is waited for

    /// How often the engine looks in on the pieces readers are waiting for.
    static let watchInterval = Duration.seconds(2)
    /// A wait this long is worth a line in the log, and another each time it doubles.
    static let longWait = Duration.seconds(10)

    /// Starts the watch if it is not running. It stops by itself when nothing is waited for.
    func startWatching() {
        guard watchTask == nil, !isShutDown else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard !Task.isCancelled, await self?.lookInOnWaiters() == true else { break }
            }
            await self?.watchEnded()
        }
    }

    private func watchEnded() {
        watchTask = nil
        // Someone may have started waiting while the watch was on its way out.
        if torrents.values.contains(where: { !$0.pieceWaiters.isEmpty }) {
            startWatching()
        }
    }

    /// Returns whether anything is still being waited for.
    ///
    /// A reader is woken by the session's "piece finished" event. Events can be dropped when
    /// the session's queue overflows, and a reader left waiting for a piece that is already
    /// there waits for ever; so the session is also asked directly, now and then. A long wait
    /// is logged with what the torrent was doing, so that "it would not play" can be told
    /// apart afterwards: nobody to fetch from, or too slow, or something else.
    func lookInOnWaiters() -> Bool {
        var isWaiting = false
        for (infoHash, torrent) in torrents {
            for piece in torrent.pieceWaiters.keys.sorted() where torrent.pieceWaiters[piece]?.isEmpty == false {
                if session.torrent(infoHash, hasPiece: piece) {
                    logger.notice("piece \(piece, privacy: .public) of \(infoHash.prefix(8), privacy: .public) was there without its event")
                    handle(.pieceFinished(infoHash, piece))
                    continue
                }
                isWaiting = true
                noteLongWait(for: piece, of: infoHash, since: torrent.waitingSince[piece])
            }
            let stale = torrent.waitingSince.keys.filter { torrents[infoHash]?.pieceWaiters[$0]?.isEmpty != false }
            for piece in stale {
                torrents[infoHash]?.waitingSince[piece] = nil
            }
        }
        return isWaiting
    }

    private func noteLongWait(for piece: Int, of infoHash: String, since start: ContinuousClock.Instant?) {
        guard let start else { return }
        let waited = ContinuousClock.now - start
        // At 10, 20, 40, 80… seconds: the watch comes by every two.
        var mark = Self.longWait
        while mark * 2 <= waited {
            mark *= 2
        }
        guard waited >= mark, waited < mark + Self.watchInterval, let status = session.status(ofTorrent: infoHash) else { return }
        let seconds = Int(waited / .seconds(1))
        logger.notice("""
        waited \(seconds, privacy: .public) s for piece \(piece, privacy: .public) of \(infoHash.prefix(8), privacy: .public): \
        \(status.connectedPeers, privacy: .public) peers, \(status.connectedSeeds, privacy: .public) seeds, \
        \(status.downloadRate / 1000, privacy: .public) kB/s
        """)
    }
}
