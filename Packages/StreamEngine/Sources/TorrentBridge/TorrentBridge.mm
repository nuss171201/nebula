#import "TorrentBridge.h"

#include <atomic>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/ip_filter.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>

namespace {

NSString *toNSString(const std::string &text) {
    return [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding] ?: @"";
}

std::string toStdString(NSString *text) {
    const char *utf8 = text.UTF8String;
    return utf8 ? std::string(utf8) : std::string();
}

NSString *hashString(const lt::sha1_hash &hash) {
    return toNSString(lt::aux::to_hex(hash));
}

/// Parses 40 hexadecimal characters into a version 1 info hash.
bool parseInfoHash(NSString *text, lt::sha1_hash &hash) {
    const std::string hex = toStdString(text.lowercaseString);
    if (hex.size() != 40) {
        return false;
    }
    return lt::aux::from_hex(hex, hash.data());
}

lt::settings_pack makeSettings(TBSessionSettings *settings) {
    lt::settings_pack pack;
    pack.set_str(lt::settings_pack::user_agent, toStdString(settings.userAgent));
    pack.set_str(lt::settings_pack::listen_interfaces, toStdString(settings.listenInterfaces));
    // The hash table's alerts are always wanted: one of them says when it is ready to be asked.
    lt::alert_category_t mask = lt::alert_category::error | lt::alert_category::status | lt::alert_category::storage
        | lt::alert_category::piece_progress | lt::alert_category::dht;
    if (settings.diagnosticLevel >= 1) {
        mask |= lt::alert_category::tracker | lt::alert_category::port_mapping;
    }
    if (settings.diagnosticLevel >= 2) {
        mask |= lt::alert_category::session_log | lt::alert_category::dht_log | lt::alert_category::connect
            | lt::alert_category::peer;
    }
    pack.set_int(lt::settings_pack::alert_mask, static_cast<int>(static_cast<std::uint32_t>(mask)));
    pack.set_int(lt::settings_pack::connections_limit, static_cast<int>(settings.connectionsLimit));
    pack.set_int(lt::settings_pack::download_rate_limit, static_cast<int>(settings.downloadRateLimit));
    pack.set_int(lt::settings_pack::upload_rate_limit, static_cast<int>(settings.uploadRateLimit));
    pack.set_bool(lt::settings_pack::enable_dht, settings.usesDHT);
    pack.set_bool(lt::settings_pack::enable_lsd, settings.usesLocalDiscovery);
    pack.set_bool(lt::settings_pack::enable_upnp, settings.mapsPorts);
    pack.set_bool(lt::settings_pack::enable_natpmp, settings.mapsPorts);
    pack.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, settings.allowsSeveralConnectionsPerAddress);
    if (settings.usesDHT) {
        // Where a hash table that knows nobody yet asks first. libtorrent's own default is the
        // first of these alone; the others are the routers every client starts from.
        pack.set_str(lt::settings_pack::dht_bootstrap_nodes,
                     "dht.libtorrent.org:25401,router.bittorrent.com:6881,dht.transmissionbt.com:6881,router.utorrent.com:6881");
    }
    // Every tracker a stream names is asked at once. The default asks one, and moves to the
    // next only when that one has failed, which with a list of dead trackers takes minutes.
    pack.set_bool(lt::settings_pack::announce_to_all_trackers, true);
    pack.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    // A torrent that has everything it wants for the moment is "finished" to libtorrent, which
    // then hangs up on every seed. For a stream that moment comes whenever the download gets
    // ahead of the player, and the seeds are needed again seconds later.
    pack.set_bool(lt::settings_pack::close_redundant_connections, false);
    // The app says who it is in `user_agent`; the peer id keeps libtorrent's own prefix.
    pack.set_bool(lt::settings_pack::anonymous_mode, false);
    return pack;
}

} // namespace

@implementation TBSessionSettings

- (instancetype)init {
    if ((self = [super init])) {
        _userAgent = @"libtorrent";
        _listenInterfaces = @"0.0.0.0:0,[::]:0";
        _connectionsLimit = 200;
        _usesDHT = YES;
        _usesLocalDiscovery = YES;
        _mapsPorts = YES;
    }
    return self;
}

@end

@interface TBFile ()
- (instancetype)initWithIndex:(NSInteger)index path:(NSString *)path size:(int64_t)size offset:(int64_t)offset;
@end

@implementation TBFile

- (instancetype)initWithIndex:(NSInteger)index path:(NSString *)path size:(int64_t)size offset:(int64_t)offset {
    if ((self = [super init])) {
        _index = index;
        _path = [path copy];
        _size = size;
        _offset = offset;
    }
    return self;
}

@end

@interface TBTorrentInfo ()
- (instancetype)initWithInfo:(const lt::torrent_info &)info;
@end

@implementation TBTorrentInfo

- (instancetype)initWithInfo:(const lt::torrent_info &)info {
    if ((self = [super init])) {
        _name = toNSString(info.name());
        _pieceLength = info.piece_length();
        _pieceCount = info.num_pieces();
        _totalSize = info.total_size();
        const lt::file_storage &storage = info.files();
        NSMutableArray<TBFile *> *files = [NSMutableArray arrayWithCapacity:static_cast<NSUInteger>(storage.num_files())];
        for (const lt::file_index_t file : storage.file_range()) {
            // Padding entries exist only to align real files to piece boundaries.
            if (storage.pad_file_at(file)) {
                continue;
            }
            [files addObject:[[TBFile alloc] initWithIndex:static_cast<int>(file)
                                                      path:toNSString(storage.file_path(file))
                                                      size:storage.file_size(file)
                                                    offset:storage.file_offset(file)]];
        }
        _files = [files copy];
    }
    return self;
}

@end

@interface TBTorrentStatus ()
- (instancetype)initWithStatus:(const lt::torrent_status &)status;
@end

@implementation TBTorrentStatus

- (instancetype)initWithStatus:(const lt::torrent_status &)status {
    if ((self = [super init])) {
        _hasMetadata = status.has_metadata;
        _downloadRate = status.download_payload_rate;
        _uploadRate = status.upload_payload_rate;
        _connectedPeers = status.num_peers;
        _connectedSeeds = status.num_seeds;
        _wantedBytes = status.total_wanted;
        _wantedBytesDone = status.total_wanted_done;
        _isFinished = status.is_finished;
        _isChecking = status.state == lt::torrent_status::checking_files
            || status.state == lt::torrent_status::checking_resume_data;
        _errorMessage = status.errc ? toNSString(status.errc.message()) : nil;
    }
    return self;
}

@end

@implementation TBSession {
    std::unique_ptr<lt::session> _session;
    std::mutex _mutex;
    std::unordered_map<std::string, lt::torrent_handle> _handles;
    __weak id<TBSessionDelegate> _delegate;
    dispatch_queue_t _events;
    std::atomic<bool> _isShutDown;
    std::atomic<bool> _logs;
}

- (instancetype)initWithSettings:(TBSessionSettings *)settings delegate:(id<TBSessionDelegate>)delegate {
    if ((self = [super init])) {
        _delegate = delegate;
        _events = dispatch_queue_create("torrent.bridge.events", DISPATCH_QUEUE_SERIAL);
        _isShutDown = false;
        _logs = settings.diagnosticLevel > 0;
        lt::session_params params(makeSettings(settings));
        _session = std::make_unique<lt::session>(std::move(params));
        if (settings.limitsPeersOnThisMachine) {
            // libtorrent puts peers on the local network and on this machine in a class of
            // their own, which the rate limits do not touch. With this, every peer is in the
            // class the limits apply to.
            const std::uint32_t everyone = 1u << static_cast<std::uint32_t>(lt::session::global_peer_class_id);
            lt::ip_filter filter;
            filter.add_rule(lt::make_address("0.0.0.0"), lt::make_address("255.255.255.255"), everyone);
            filter.add_rule(lt::make_address("::"), lt::make_address("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"), everyone);
            _session->set_peer_class_filter(filter);
        }

        // libtorrent calls this from its own thread when there is something to collect, and
        // must not be called back from inside it: hand over to the events queue.
        __weak TBSession *weakSelf = self;
        dispatch_queue_t events = _events;
        _session->set_alert_notify([weakSelf, events] {
            dispatch_async(events, ^{
                [weakSelf drainAlerts];
            });
        });
    }
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (NSInteger)listenPort {
    return _session ? _session->listen_port() : 0;
}

- (void)applySettings:(TBSessionSettings *)settings {
    if (_session) {
        _logs = settings.diagnosticLevel > 0;
        _session->apply_settings(makeSettings(settings));
    }
}

#pragma mark - Torrents

- (BOOL)addTorrentWithInfoHash:(NSString *)infoHash
                      trackers:(NSArray<NSString *> *)trackers
                     directory:(NSString *)directory
                         error:(NSString *_Nullable *_Nullable)message {
    lt::sha1_hash hash;
    if (!_session || !parseInfoHash(infoHash, hash)) {
        if (message) {
            *message = @"That is not a torrent info hash.";
        }
        return NO;
    }
    lt::add_torrent_params params;
    params.info_hashes = lt::info_hash_t(hash);
    params.save_path = toStdString(directory);
    for (NSString *tracker in trackers) {
        params.trackers.push_back(toStdString(tracker));
    }
    // Nothing is wanted until the caller has seen the file list and chosen.
    params.flags |= lt::torrent_flags::default_dont_download;
    // In file order, which is playing order: without this the pieces of equal priority come
    // rarest first, which between seeds means at random.
    params.flags |= lt::torrent_flags::sequential_download;
    params.flags &= ~lt::torrent_flags::auto_managed;
    params.flags &= ~lt::torrent_flags::paused;
    return [self add:std::move(params) error:message] != nil;
}

- (nullable NSString *)addTorrentFile:(NSString *)path
                            directory:(NSString *)directory
                                error:(NSString *_Nullable *_Nullable)message {
    if (!_session) {
        return nil;
    }
    lt::error_code error;
    auto info = std::make_shared<lt::torrent_info>(toStdString(path), error);
    if (error) {
        if (message) {
            *message = toNSString(error.message());
        }
        return nil;
    }
    lt::add_torrent_params params;
    params.ti = info;
    params.save_path = toStdString(directory);
    params.flags &= ~lt::torrent_flags::auto_managed;
    params.flags &= ~lt::torrent_flags::paused;
    return [self add:std::move(params) error:message];
}

/// Adds the torrent and remembers its handle under its info hash.
- (nullable NSString *)add:(lt::add_torrent_params)params error:(NSString *_Nullable *_Nullable)message {
    lt::error_code error;
    lt::torrent_handle handle = _session->add_torrent(std::move(params), error);
    if (error || !handle.is_valid()) {
        if (message) {
            *message = error ? toNSString(error.message()) : @"The torrent could not be added.";
        }
        return nil;
    }
    NSString *name = hashString(handle.info_hashes().get_best());
    {
        std::lock_guard<std::mutex> lock(_mutex);
        _handles[toStdString(name)] = handle;
    }
    return name;
}

- (lt::torrent_handle)handleFor:(NSString *)infoHash {
    std::lock_guard<std::mutex> lock(_mutex);
    auto found = _handles.find(toStdString(infoHash.lowercaseString));
    return found == _handles.end() ? lt::torrent_handle() : found->second;
}

- (void)removeTorrent:(NSString *)infoHash deletingFiles:(BOOL)deletesFiles {
    lt::torrent_handle handle;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        auto found = _handles.find(toStdString(infoHash.lowercaseString));
        if (found == _handles.end()) {
            return;
        }
        handle = found->second;
        _handles.erase(found);
    }
    if (_session && handle.is_valid()) {
        _session->remove_torrent(handle, deletesFiles ? lt::session_handle::delete_files : lt::remove_flags_t{});
    }
}

- (nullable TBTorrentInfo *)infoForTorrent:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleFor:infoHash];
    if (!handle.is_valid()) {
        return nil;
    }
    std::shared_ptr<const lt::torrent_info> info = handle.torrent_file();
    return info ? [[TBTorrentInfo alloc] initWithInfo:*info] : nil;
}

- (nullable TBTorrentStatus *)statusOfTorrent:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleFor:infoHash];
    if (!handle.is_valid()) {
        return nil;
    }
    return [[TBTorrentStatus alloc] initWithStatus:handle.status({})];
}

- (BOOL)torrent:(NSString *)infoHash hasPiece:(NSInteger)piece {
    lt::torrent_handle handle = [self handleFor:infoHash];
    return handle.is_valid() && piece >= 0 && handle.have_piece(lt::piece_index_t(static_cast<int>(piece)));
}

- (NSIndexSet *)completedPiecesOfTorrent:(NSString *)infoHash {
    NSMutableIndexSet *pieces = [NSMutableIndexSet indexSet];
    lt::torrent_handle handle = [self handleFor:infoHash];
    if (!handle.is_valid()) {
        return pieces;
    }
    const lt::torrent_status status = handle.status(lt::torrent_handle::query_pieces);
    int index = 0;
    for (const bool isComplete : status.pieces) {
        if (isComplete) {
            [pieces addIndex:static_cast<NSUInteger>(index)];
        }
        ++index;
    }
    return pieces;
}

- (NSDictionary<NSNumber *, NSNumber *> *)partialPieceBytesOfTorrent:(NSString *)infoHash {
    NSMutableDictionary<NSNumber *, NSNumber *> *bytes = [NSMutableDictionary dictionary];
    lt::torrent_handle handle = [self handleFor:infoHash];
    if (!handle.is_valid()) {
        return bytes;
    }
    std::vector<lt::partial_piece_info> queue;
    handle.get_download_queue(queue);
    for (const lt::partial_piece_info &piece : queue) {
        int64_t arrived = 0;
        for (int block = 0; block < piece.blocks_in_piece; ++block) {
            const lt::block_info &info = piece.blocks[block];
            // A block that is written or being written is all there; one on its way counts
            // for what has come of it.
            arrived += (info.state == lt::block_info::finished || info.state == lt::block_info::writing)
                ? info.block_size
                : info.bytes_progress;
        }
        bytes[@(static_cast<int>(piece.piece_index))] = @(arrived);
    }
    return bytes;
}

- (void)wantOnlyFile:(NSInteger)fileIndex ofTorrent:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleFor:infoHash];
    std::shared_ptr<const lt::torrent_info> info = handle.is_valid() ? handle.torrent_file() : nullptr;
    if (!info) {
        return;
    }
    std::vector<lt::download_priority_t> priorities(static_cast<std::size_t>(info->num_files()), lt::dont_download);
    if (fileIndex >= 0 && fileIndex < info->num_files()) {
        priorities[static_cast<std::size_t>(fileIndex)] = lt::low_priority;
    }
    handle.prioritize_files(priorities);
}

- (void)setDeadlines:(NSDictionary<NSNumber *, NSNumber *> *)deadlines
     clearDeadlines:(NSArray<NSNumber *> *)cleared
         priorities:(NSDictionary<NSNumber *, NSNumber *> *)priorities
          ofTorrent:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleFor:infoHash];
    if (!handle.is_valid()) {
        return;
    }
    for (NSNumber *piece in cleared) {
        handle.reset_piece_deadline(lt::piece_index_t(piece.intValue));
    }
    // In one call: a plan for a large file names tens of thousands of pieces.
    __block std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> levels;
    levels.reserve(priorities.count);
    [priorities enumerateKeysAndObjectsUsingBlock:^(NSNumber *piece, NSNumber *priority, BOOL *) {
        const int level = std::min(std::max(priority.intValue, 0), 7);
        levels.emplace_back(lt::piece_index_t(piece.intValue), lt::download_priority_t(static_cast<std::uint8_t>(level)));
    }];
    if (!levels.empty()) {
        handle.prioritize_pieces(levels);
    }
    [deadlines enumerateKeysAndObjectsUsingBlock:^(NSNumber *piece, NSNumber *milliseconds, BOOL *) {
        handle.set_piece_deadline(lt::piece_index_t(piece.intValue), milliseconds.intValue);
    }];
}

- (void)readPiece:(NSInteger)piece ofTorrent:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleFor:infoHash];
    if (!handle.is_valid() || piece < 0) {
        id<TBSessionDelegate> delegate = _delegate;
        dispatch_async(_events, ^{
            [delegate torrent:infoHash didReadPiece:piece data:nil error:@"There is no such torrent."];
        });
        return;
    }
    handle.read_piece(lt::piece_index_t(static_cast<int>(piece)));
}

- (void)lookForPeersOfTorrent:(NSString *)infoHash {
    lt::torrent_handle handle = [self handleFor:infoHash];
    if (handle.is_valid()) {
        handle.force_dht_announce();
    }
}

- (void)connectTorrent:(NSString *)infoHash toPeerAtAddress:(NSString *)address port:(NSInteger)port {
    lt::torrent_handle handle = [self handleFor:infoHash];
    lt::error_code error;
    const lt::address parsed = lt::make_address(toStdString(address), error);
    if (!handle.is_valid() || error || port <= 0 || port > 65535) {
        return;
    }
    handle.connect_peer(lt::tcp::endpoint(parsed, static_cast<unsigned short>(port)));
}

#pragma mark - Events

- (void)drainAlerts {
    if (_isShutDown.load() || !_session) {
        return;
    }
    std::vector<lt::alert *> alerts;
    _session->pop_alerts(&alerts);
    id<TBSessionDelegate> delegate = _delegate;
    if (!delegate) {
        return;
    }
    const bool logs = _logs.load() && [delegate respondsToSelector:@selector(sessionDidLog:)];
    for (lt::alert *alert : alerts) {
        if (auto *metadata = lt::alert_cast<lt::metadata_received_alert>(alert)) {
            [delegate torrentDidReceiveMetadata:hashString(metadata->handle.info_hashes().get_best())];
        } else if (auto *finished = lt::alert_cast<lt::piece_finished_alert>(alert)) {
            [delegate torrent:hashString(finished->handle.info_hashes().get_best())
                didFinishPiece:static_cast<int>(finished->piece_index)];
        } else if (auto *read = lt::alert_cast<lt::read_piece_alert>(alert)) {
            NSString *name = hashString(read->handle.info_hashes().get_best());
            if (read->error || !read->buffer) {
                [delegate torrent:name
                     didReadPiece:static_cast<int>(read->piece)
                             data:nil
                            error:toNSString(read->error ? read->error.message() : std::string("The piece could not be read."))];
            } else {
                // Copied: the buffer belongs to libtorrent and goes away with the alert.
                NSData *data = [NSData dataWithBytes:read->buffer.get() length:static_cast<NSUInteger>(read->size)];
                [delegate torrent:name didReadPiece:static_cast<int>(read->piece) data:data error:nil];
            }
        } else if (auto *failed = lt::alert_cast<lt::torrent_error_alert>(alert)) {
            [delegate torrent:hashString(failed->handle.info_hashes().get_best())
                didFailWithMessage:toNSString(failed->error.message())];
        } else if (auto *fileError = lt::alert_cast<lt::file_error_alert>(alert)) {
            [delegate torrent:hashString(fileError->handle.info_hashes().get_best())
                didFailWithMessage:toNSString(fileError->error.message())];
        } else if (auto *chosen = lt::alert_cast<lt::file_prio_alert>(alert)) {
            if ([delegate respondsToSelector:@selector(torrentDidApplyFileChoice:)]) {
                [delegate torrentDidApplyFileChoice:hashString(chosen->handle.info_hashes().get_best())];
            }
        } else if (lt::alert_cast<lt::dht_bootstrap_alert>(alert)) {
            // A torrent added before the hash table was up was never looked for in it:
            // libtorrent only asks at once for torrents added while the table is running, and
            // otherwise leaves them to a round that comes every fifteen minutes.
            [self announceEveryTorrent];
            if (logs) {
                [delegate sessionDidLog:@"the hash table is ready"];
            }
        } else if (logs && !(alert->category() & lt::alert_category::piece_progress)) {
            // Everything else, in libtorrent's words; the block-by-block chatter is left out.
            [delegate sessionDidLog:toNSString(std::string(alert->what()) + ": " + alert->message())];
        }
    }
}

/// Asks the hash table for people sharing each torrent, now.
- (void)announceEveryTorrent {
    std::vector<lt::torrent_handle> handles;
    {
        std::lock_guard<std::mutex> lock(_mutex);
        for (const auto &entry : _handles) {
            handles.push_back(entry.second);
        }
    }
    for (const lt::torrent_handle &handle : handles) {
        if (handle.is_valid()) {
            handle.force_dht_announce();
        }
    }
}

- (void)shutdown {
    if (_isShutDown.exchange(true)) {
        return;
    }
    if (_session) {
        _session->set_alert_notify([] {});
        {
            std::lock_guard<std::mutex> lock(_mutex);
            _handles.clear();
        }
        // Destroying the session waits for its threads; trackers are told the client has left.
        _session.reset();
    }
}

#pragma mark - Making torrents

+ (nullable NSString *)createTorrentForFile:(NSString *)path
                                pieceLength:(NSInteger)pieceLength
                                     output:(NSString *)outputPath
                                      error:(NSString *_Nullable *_Nullable)message {
    try {
        lt::file_storage storage;
        lt::add_files(storage, toStdString(path));
        if (storage.num_files() == 0) {
            if (message) {
                *message = @"There is no file there.";
            }
            return nil;
        }
        lt::create_torrent torrent(storage, static_cast<int>(pieceLength), lt::create_torrent::v1_only);
        lt::error_code error;
        lt::set_piece_hashes(torrent, toStdString(path.stringByDeletingLastPathComponent), error);
        if (error) {
            if (message) {
                *message = toNSString(error.message());
            }
            return nil;
        }
        std::vector<char> encoded;
        lt::bencode(std::back_inserter(encoded), torrent.generate());
        std::ofstream output(toStdString(outputPath), std::ios::binary | std::ios::trunc);
        output.write(encoded.data(), static_cast<std::streamsize>(encoded.size()));
        output.close();
        if (!output) {
            if (message) {
                *message = @"The torrent file could not be written.";
            }
            return nil;
        }
        lt::torrent_info info(encoded, error, lt::from_span);
        if (error) {
            if (message) {
                *message = toNSString(error.message());
            }
            return nil;
        }
        return hashString(info.info_hashes().get_best());
    } catch (const std::exception &exception) {
        if (message) {
            *message = toNSString(exception.what());
        }
        return nil;
    }
}

@end
