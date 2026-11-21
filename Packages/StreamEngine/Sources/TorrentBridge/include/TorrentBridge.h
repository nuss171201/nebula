// A thin Objective-C face on libtorrent, so that Swift never sees C++.
//
// Everything here is plain data in and out. A torrent is named by its (version 1) info
// hash as 40 lower-case hexadecimal characters. All methods may be called from any thread.
// Events are delivered to the delegate one at a time on a private queue.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How a session behaves. Rates are bytes per second; 0 means no limit.
@interface TBSessionSettings : NSObject
@property (nonatomic, copy) NSString *userAgent;
/// Addresses and ports to listen on, in libtorrent's notation ("0.0.0.0:0,[::]:0" picks free ports).
@property (nonatomic, copy) NSString *listenInterfaces;
@property (nonatomic) NSInteger connectionsLimit;
@property (nonatomic) NSInteger downloadRateLimit;
@property (nonatomic) NSInteger uploadRateLimit;
/// Finding peers without a tracker: the distributed hash table, and broadcasts on the local network.
@property (nonatomic) BOOL usesDHT;
@property (nonatomic) BOOL usesLocalDiscovery;
/// Asking the router to forward the listening port (UPnP and NAT-PMP).
@property (nonatomic) BOOL mapsPorts;
/// Allows several peers at one address. Only wanted when the peers are on this machine, as in tests.
@property (nonatomic) BOOL allowsSeveralConnectionsPerAddress;
/// How much the session says about what it is doing, through `-sessionDidLog:`: 0 nothing,
/// 1 the events that explain a slow start (listening, trackers, the hash table, port mapping),
/// 2 libtorrent's own running commentary as well. For finding out why nobody is found.
@property (nonatomic) NSInteger diagnosticLevel;
@end

/// One file of a torrent.
@interface TBFile : NSObject
@property (nonatomic, readonly) NSInteger index;
/// Path inside the torrent, with "/" between folders.
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) int64_t size;
/// Where the file starts in the torrent's data.
@property (nonatomic, readonly) int64_t offset;
@end

/// What is known about a torrent once its description (the "metadata") has arrived.
@interface TBTorrentInfo : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) int64_t pieceLength;
@property (nonatomic, readonly) NSInteger pieceCount;
@property (nonatomic, readonly) int64_t totalSize;
@property (nonatomic, readonly, copy) NSArray<TBFile *> *files;
@end

/// A moment's reading of how a torrent is doing.
@interface TBTorrentStatus : NSObject
@property (nonatomic, readonly) BOOL hasMetadata;
/// Bytes per second.
@property (nonatomic, readonly) NSInteger downloadRate;
@property (nonatomic, readonly) NSInteger uploadRate;
@property (nonatomic, readonly) NSInteger connectedPeers;
@property (nonatomic, readonly) NSInteger connectedSeeds;
/// Of the files that are wanted.
@property (nonatomic, readonly) int64_t wantedBytes;
@property (nonatomic, readonly) int64_t wantedBytesDone;
@property (nonatomic, readonly) BOOL isFinished;
/// Why the torrent stopped, if it did.
@property (nonatomic, readonly, copy, nullable) NSString *errorMessage;
@end

@protocol TBSessionDelegate <NSObject>
/// The torrent's description has arrived; `-infoForTorrent:` now answers.
- (void)torrentDidReceiveMetadata:(NSString *)infoHash;
/// A piece has been downloaded and verified.
- (void)torrent:(NSString *)infoHash didFinishPiece:(NSInteger)piece;
/// The answer to `-readPiece:ofTorrent:`. `data` is nil if the piece could not be read.
- (void)torrent:(NSString *)infoHash didReadPiece:(NSInteger)piece data:(nullable NSData *)data error:(nullable NSString *)message;
/// The torrent cannot go on (disk full, files unreadable, …).
- (void)torrent:(NSString *)infoHash didFailWithMessage:(NSString *)message;
@optional
/// The choice of file made with `-wantOnlyFile:ofTorrent:` has taken effect. libtorrent resets
/// every piece's priority to its file's at that moment, so priorities set before it are gone.
- (void)torrentDidApplyFileChoice:(NSString *)infoHash;
/// Something the session did or met, in libtorrent's words. Only with a diagnostic level above 0.
- (void)sessionDidLog:(NSString *)line;
@end

@interface TBSession : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithSettings:(TBSessionSettings *)settings delegate:(id<TBSessionDelegate>)delegate NS_DESIGNATED_INITIALIZER;

/// The TCP port the session ended up listening on; 0 until it is.
@property (nonatomic, readonly) NSInteger listenPort;

- (void)applySettings:(TBSessionSettings *)settings;

/// Starts fetching the torrent with this info hash. Nothing of it is downloaded until
/// priorities say so: every file starts as "not wanted".
/// @param trackers Tracker addresses to ask for peers, in addition to the hash table.
/// @param directory Where the torrent's files are kept.
/// @return NO with a reason if the hash is malformed or the torrent could not be added.
- (BOOL)addTorrentWithInfoHash:(NSString *)infoHash
                      trackers:(NSArray<NSString *> *)trackers
                     directory:(NSString *)directory
                         error:(NSString *_Nullable *_Nullable)message;

/// Adds a torrent from a .torrent file whose data is already in `directory`, to share it.
/// @return The torrent's info hash, or nil with a reason.
- (nullable NSString *)addTorrentFile:(NSString *)path
                            directory:(NSString *)directory
                                error:(NSString *_Nullable *_Nullable)message;

- (void)removeTorrent:(NSString *)infoHash deletingFiles:(BOOL)deletesFiles;

/// nil until the metadata has arrived, or if there is no such torrent.
- (nullable TBTorrentInfo *)infoForTorrent:(NSString *)infoHash;
- (nullable TBTorrentStatus *)statusOfTorrent:(NSString *)infoHash;
- (BOOL)torrent:(NSString *)infoHash hasPiece:(NSInteger)piece;
/// Every piece that has been downloaded and verified so far, in one call.
- (NSIndexSet *)completedPiecesOfTorrent:(NSString *)infoHash;

/// Marks one file as wanted and all others as not.
- (void)wantOnlyFile:(NSInteger)fileIndex ofTorrent:(NSString *)infoHash;

/// Changes what is fetched first.
/// @param deadlines Piece index to milliseconds from now: these are fetched ahead of everything.
/// @param cleared Pieces that no longer have a deadline.
/// @param priorities Piece index to priority, 0 (never) to 7 (keenest).
- (void)setDeadlines:(NSDictionary<NSNumber *, NSNumber *> *)deadlines
     clearDeadlines:(NSArray<NSNumber *> *)cleared
         priorities:(NSDictionary<NSNumber *, NSNumber *> *)priorities
          ofTorrent:(NSString *)infoHash;

/// Reads a complete piece from disk; the delegate gets the answer.
- (void)readPiece:(NSInteger)piece ofTorrent:(NSString *)infoHash;

/// Asks the hash table for people sharing the torrent, now. Does nothing if it is not running.
- (void)lookForPeersOfTorrent:(NSString *)infoHash;

/// Tells the torrent about a peer directly.
- (void)connectTorrent:(NSString *)infoHash toPeerAtAddress:(NSString *)address port:(NSInteger)port;

/// Stops everything and waits for the session to close. The session cannot be used afterwards.
- (void)shutdown;

/// Writes a .torrent file describing one file on disk (version 1 only, no trackers).
/// @return The new torrent's info hash, or nil with a reason.
+ (nullable NSString *)createTorrentForFile:(NSString *)path
                                pieceLength:(NSInteger)pieceLength
                                     output:(NSString *)outputPath
                                      error:(NSString *_Nullable *_Nullable)message;

@end

NS_ASSUME_NONNULL_END
