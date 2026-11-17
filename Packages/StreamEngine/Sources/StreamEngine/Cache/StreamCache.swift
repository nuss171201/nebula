import Foundation

/// How much disk the stream cache may use.
public struct StreamCachePolicy: Sendable, Equatable {
    /// Bytes on disk the cache may hold once nothing is playing.
    public var maximumBytes: Int64

    public init(maximumBytes: Int64 = 10 << 30) {
        self.maximumBytes = max(maximumBytes, 0)
    }
}

/// One torrent's data in the cache.
public struct StreamCacheEntry: Sendable, Equatable {
    /// The torrent's info hash, which is also its folder's name.
    public var id: String
    /// Bytes actually on disk: files are sparse while a torrent is incomplete.
    public var bytes: Int64
    public var lastUsed: Date

    public init(id: String, bytes: Int64, lastUsed: Date) {
        self.id = id
        self.bytes = bytes
        self.lastUsed = lastUsed
    }
}

/// The folder where streamed torrents keep their data, one subfolder per torrent, and the
/// rule for clearing it: least recently watched first, until it fits the budget; what is
/// playing is never removed.
public struct StreamCache: Sendable {
    public let directory: URL
    public var policy: StreamCachePolicy

    public init(directory: URL, policy: StreamCachePolicy = StreamCachePolicy()) {
        self.directory = directory
        self.policy = policy
    }

    /// Which entries to delete so that what is left fits `budget`: oldest first, never an active one.
    public static func evictions(entries: [StreamCacheEntry], active: Set<String>, budget: Int64) -> [String] {
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var removed: [String] = []
        for entry in entries.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > budget {
            guard !active.contains(entry.id) else { continue }
            total -= entry.bytes
            removed.append(entry.id)
        }
        return removed
    }

    /// Whether a file of this size can be kept whole within the budget.
    public func canHoldWholeFile(ofSize size: Int64) -> Bool {
        size <= policy.maximumBytes
    }

    /// What is in the cache now.
    public func entries(fileManager: FileManager = .default) -> [StreamCacheEntry] {
        let folders = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return folders.compactMap { folder in
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { return nil }
            return StreamCacheEntry(
                id: folder.lastPathComponent,
                bytes: Self.allocatedSize(of: folder, fileManager: fileManager),
                lastUsed: values?.contentModificationDate ?? .distantPast
            )
        }
    }

    /// Bytes the cache occupies on disk.
    public func totalBytes(fileManager: FileManager = .default) -> Int64 {
        entries(fileManager: fileManager).reduce(0) { $0 + $1.bytes }
    }

    /// Notes that a torrent has just been watched, so it is the last to be cleared.
    public func markUsed(_ id: String, now: Date = Date(), fileManager: FileManager = .default) {
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: folder.path)
    }

    /// Deletes least recently used torrents until the cache fits its budget. Returns what was removed.
    @discardableResult
    public func trim(active: Set<String>, fileManager: FileManager = .default) -> [String] {
        let removed = Self.evictions(entries: entries(fileManager: fileManager), active: active, budget: policy.maximumBytes)
        for id in removed {
            try? fileManager.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
        }
        return removed
    }

    /// Deletes everything that is not playing. Returns the bytes freed.
    @discardableResult
    public func clear(active: Set<String>, fileManager: FileManager = .default) -> Int64 {
        var freed: Int64 = 0
        for entry in entries(fileManager: fileManager) where !active.contains(entry.id) {
            freed += entry.bytes
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry.id, isDirectory: true))
        }
        return freed
    }

    static func allocatedSize(of folder: URL, fileManager: FileManager) -> Int64 {
        let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
