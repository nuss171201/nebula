import WatchParty

/// A signalling server on 127.0.0.1, inside the test process: the app's own party server
/// (`PartyHostServer`), reachable from this machine only.
public typealias LoopbackSignalServer = PartyHostServer
