import Foundation

/// A torrent to fetch: its info hash, and optionally trackers to ask for peers.
public struct TorrentSource: Sendable, Hashable {
    /// 40 lower-case hexadecimal characters (a version 1 info hash).
    public let infoHash: String
    public var trackers: [String]

    /// `nil` if `infoHash` is not 40 hexadecimal characters.
    public init?(infoHash: String, trackers: [String] = []) {
        let hash = infoHash.lowercased()
        guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { return nil }
        self.infoHash = hash
        // Trackers are web or UDP addresses; anything else an add-on sends is dropped.
        self.trackers = trackers.filter { tracker in
            ["http://", "https://", "udp://"].contains { tracker.lowercased().hasPrefix($0) }
        }
    }
}

/// One file of a torrent.
public struct TorrentFile: Sendable, Hashable, Identifiable {
    /// The file's number in the torrent, which is how add-ons refer to it.
    public let index: Int
    /// Path inside the torrent, with "/" between folders.
    public let path: String
    public let size: Int64
    /// Where the file starts in the torrent's data.
    public let offset: Int64

    public var id: Int { index }

    public var name: String {
        (path as NSString).lastPathComponent
    }
}

/// What a torrent's description says about it.
public struct TorrentInfo: Sendable, Hashable {
    public let name: String
    public let pieceLength: Int64
    public let pieceCount: Int
    public let totalSize: Int64
    public let files: [TorrentFile]

    /// Where a file sits among the pieces; `nil` if the torrent has no file with that number.
    public func pieceMap(forFile index: Int) -> PieceMap? {
        files.first { $0.index == index }.map { PieceMap(pieceLength: pieceLength, fileOffset: $0.offset, fileSize: $0.size) }
    }
}

/// A moment's reading of how a torrent is doing.
public struct TorrentStatus: Sendable, Equatable {
    public var hasMetadata: Bool
    /// Bytes per second.
    public var downloadRate: Int
    public var uploadRate: Int
    public var peers: Int
    public var seeds: Int
    /// Of the file being played.
    public var wantedBytes: Int64
    public var wantedBytesDone: Int64
    public var isFinished: Bool
    public var errorMessage: String?

    public init(
        hasMetadata: Bool,
        downloadRate: Int,
        uploadRate: Int,
        peers: Int,
        seeds: Int,
        wantedBytes: Int64,
        wantedBytesDone: Int64,
        isFinished: Bool,
        errorMessage: String?
    ) {
        self.hasMetadata = hasMetadata
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.peers = peers
        self.seeds = seeds
        self.wantedBytes = wantedBytes
        self.wantedBytesDone = wantedBytesDone
        self.isFinished = isFinished
        self.errorMessage = errorMessage
    }

    /// How much of the wanted file is there, 0 to 1.
    public var progress: Double {
        wantedBytes > 0 ? min(max(Double(wantedBytesDone) / Double(wantedBytes), 0), 1) : 0
    }
}

public enum TorrentError: Error, Sendable, Equatable {
    case invalidSource
    /// Carries the engine's reason.
    case couldNotAdd(String)
    /// No peer sent the torrent's description in time.
    case metadataTimeout
    /// The torrent was removed, or the engine shut down, while something was waiting on it.
    case removed
    case noSuchFile
    case failed(String)

    public var userMessage: String {
        switch self {
        case .invalidSource: "This stream's torrent address is not valid."
        case let .couldNotAdd(reason): "The torrent could not be started. \(reason)"
        case .metadataTimeout: "No one sharing this torrent could be reached. It may have no one sharing it at the moment."
        case .removed: "The stream was stopped."
        case .noSuchFile: "The torrent does not contain the file this stream points to."
        case let .failed(reason): "The download stopped. \(reason)"
        }
    }
}

/// How the engine behaves on the network.
public struct TorrentEngineSettings: Sendable, Equatable {
    public var userAgent: String
    /// Addresses and ports to listen on, in libtorrent's notation. The default picks free ports.
    public var listenInterfaces: String
    public var connectionsLimit: Int
    /// Bytes per second; 0 means no limit.
    public var downloadRateLimit: Int
    public var uploadRateLimit: Int
    /// Finding peers without a tracker.
    public var usesDHT: Bool
    public var usesLocalDiscovery: Bool
    /// Asking the router to forward the listening port.
    public var mapsPorts: Bool
    /// Several peers at one address: only for peers on this machine, as in tests.
    public var allowsSeveralConnectionsPerAddress: Bool
    public var window: StreamingWindow

    public init(
        userAgent: String,
        listenInterfaces: String = "0.0.0.0:0,[::]:0",
        connectionsLimit: Int = 200,
        downloadRateLimit: Int = 0,
        uploadRateLimit: Int = 0,
        usesDHT: Bool = true,
        usesLocalDiscovery: Bool = true,
        mapsPorts: Bool = true,
        allowsSeveralConnectionsPerAddress: Bool = false,
        window: StreamingWindow = StreamingWindow()
    ) {
        self.userAgent = userAgent
        self.listenInterfaces = listenInterfaces
        self.connectionsLimit = max(connectionsLimit, 2)
        self.downloadRateLimit = max(downloadRateLimit, 0)
        self.uploadRateLimit = max(uploadRateLimit, 0)
        self.usesDHT = usesDHT
        self.usesLocalDiscovery = usesLocalDiscovery
        self.mapsPorts = mapsPorts
        self.allowsSeveralConnectionsPerAddress = allowsSeveralConnectionsPerAddress
        self.window = window
    }

    /// Everything on this machine only: no hash table, no discovery, no router. For tests.
    public static func loopback(userAgent: String = "StreamEngineTests/1.0") -> TorrentEngineSettings {
        TorrentEngineSettings(
            userAgent: userAgent,
            listenInterfaces: "127.0.0.1:0",
            usesDHT: false,
            usesLocalDiscovery: false,
            mapsPorts: false,
            allowsSeveralConnectionsPerAddress: true
        )
    }
}

/// Something bytes can be read from at any offset, perhaps after a wait: a file on disk, or
/// a file inside a torrent that is still downloading.
public protocol ByteSource: Sendable {
    /// Total length in bytes.
    var size: Int64 { get }
    /// Up to `maxLength` bytes starting at `offset`, waiting until they are there. At least
    /// one byte unless `offset` is at or past the end, when the result is empty.
    /// - Parameter reader: Names who is reading, so the source can tell several readers apart.
    func read(at offset: Int64, maxLength: Int, reader: UUID) async throws -> Data
    /// The reader has finished (or given up).
    func close(reader: UUID) async
}
