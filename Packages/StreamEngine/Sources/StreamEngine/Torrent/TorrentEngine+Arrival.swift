import Foundation
import TorrentBridge

/// Saying how far what the player is waiting for has come.
public extension TorrentEngine {
    /// How much of what the player is held up by has arrived, counting the part of a piece
    /// that is still on its way. `nil` when nothing is being waited for.
    ///
    /// A film's pieces are large (8 to 16 MiB is usual), and nothing can be read from one until
    /// all of it is there: on a slow connection that is most of a minute in which the only
    /// honest thing to show is how far the piece has come.
    func arrival(of infoHash: String) -> ArrivalProgress? {
        guard let torrent = torrents[infoHash], let info = torrent.info else { return nil }
        let awaited = torrent.streams.values.reduce(into: Set<Int>()) { $0.formUnion($1.awaited) }
        guard !awaited.isEmpty else { return nil }
        let partial = session.partialPieceBytes(ofTorrent: infoHash)
        var progress = ArrivalProgress(bytesDone: 0, bytesWanted: 0)
        for piece in awaited {
            // Every piece is the same length but the torrent's last.
            let length = min(info.pieceLength, info.totalSize - Int64(piece) * info.pieceLength)
            guard length > 0 else { continue }
            progress.bytesWanted += length
            progress.bytesDone += torrent.completed.contains(piece)
                ? length
                : min(partial[NSNumber(value: piece)]?.int64Value ?? 0, length)
        }
        return progress.bytesWanted > 0 ? progress : nil
    }

    /// Starts counting afresh: from now on `arrival(of:)` is about what readers are waiting for
    /// at this moment and what they wait for next. Called when the player stalls again, so that
    /// what held it up the last time is not counted as progress this time.
    func restartArrival(of infoHash: String) {
        guard let torrent = torrents[infoHash] else { return }
        let waitedFor = Set(torrent.pieceWaiters.filter { !$0.value.isEmpty }.keys)
        for index in torrent.streams.keys {
            guard let map = torrents[infoHash]?.streams[index]?.map else { continue }
            torrents[infoHash]?.streams[index]?.awaited = waitedFor.filter { map.pieces.contains($0) }
        }
    }
}
