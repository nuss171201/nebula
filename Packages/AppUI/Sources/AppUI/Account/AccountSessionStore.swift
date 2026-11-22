import Foundation
import Security

/// Where the session is kept between launches.
public protocol AccountSessionStore: Sendable {
    func load() -> AccountSession?
    func save(_ session: AccountSession)
    func clear()
}

/// The session in the user's keychain, where passwords and tokens belong.
public struct KeychainSessionStore: AccountSessionStore {
    private let service: String
    private static let account = "session"

    /// - Parameter service: What the item is filed under; the app's identifier plus ".account".
    public init(service: String) {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: Self.account]
    }

    public func load() -> AccountSession? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AccountSession.self, from: data)
    }

    public func save(_ session: AccountSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The session in a file of the caller's choosing: for a check's scratch profile and for
/// tests, which must not touch (or be asked about) the user's keychain. `nil` keeps it in
/// memory only.
public final class FileSessionStore: AccountSessionStore, @unchecked Sendable {
    private let file: URL?
    private let lock = NSLock()
    private var held: AccountSession?

    public init(file: URL? = nil) {
        self.file = file
    }

    public func load() -> AccountSession? {
        lock.withLock {
            if let file, let data = try? Data(contentsOf: file) {
                held = try? JSONDecoder().decode(AccountSession.self, from: data)
            }
            return held
        }
    }

    public func save(_ session: AccountSession) {
        lock.withLock {
            held = session
            guard let file, let data = try? JSONEncoder().encode(session) else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    public func clear() {
        lock.withLock {
            held = nil
            if let file {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
