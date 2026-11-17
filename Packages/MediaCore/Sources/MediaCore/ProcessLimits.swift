import Darwin

/// Limits the system puts on the process.
public enum ProcessLimits {
    /// How many files and sockets the app wants to be able to have open at once.
    public static let wantedOpenFiles: rlim_t = 4096

    /// Raises the limit on open files and sockets, which is 256 for an app started from Finder:
    /// too few for a torrent engine with a couple of hundred connections beside the player, the
    /// database and the image cache. Returns the limit in force afterwards.
    @discardableResult
    public static func raiseOpenFileLimit(to wanted: rlim_t = wantedOpenFiles) -> rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        // Never lowered, and never above what the system allows this process.
        let target = min(max(limit.rlim_cur, wanted), limit.rlim_max, rlim_t(OPEN_MAX))
        if target > limit.rlim_cur {
            limit.rlim_cur = target
            if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
                getrlimit(RLIMIT_NOFILE, &limit)
            }
        }
        return limit.rlim_cur
    }
}
