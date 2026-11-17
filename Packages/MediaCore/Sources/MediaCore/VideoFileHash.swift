import Foundation

/// The file fingerprint subtitle databases use to recognise an exact release: the file's
/// size plus the sum of its first and last 64 KiB read as 64-bit little-endian numbers.
/// Reading 128 KiB is enough, however large the file.
public enum VideoFileHash {
    public static let chunkSize = 65536

    public struct Fingerprint: Sendable, Hashable {
        /// 16 lower-case hexadecimal digits.
        public var hash: String
        /// Bytes.
        public var size: Int64

        public init(hash: String, size: Int64) {
            self.hash = hash
            self.size = size
        }
    }

    /// `nil` when the file cannot be read or is smaller than one chunk (too little to tell files apart).
    public static func fingerprint(ofFileAt url: URL) -> Fingerprint? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= UInt64(chunkSize) else { return nil }
        do {
            try handle.seek(toOffset: 0)
            let head = try handle.read(upToCount: chunkSize) ?? Data()
            try handle.seek(toOffset: size - UInt64(chunkSize))
            let tail = try handle.read(upToCount: chunkSize) ?? Data()
            guard head.count == chunkSize, tail.count == chunkSize else { return nil }
            return Fingerprint(hash: hash(head: head, tail: tail, size: size), size: Int64(size))
        } catch {
            return nil
        }
    }

    /// The sum wraps round at 64 bits, as the databases expect.
    static func hash(head: Data, tail: Data, size: UInt64) -> String {
        var sum = size
        for chunk in [head, tail] {
            chunk.withUnsafeBytes { bytes in
                var offset = 0
                while offset + 8 <= bytes.count {
                    sum &+= UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                    offset += 8
                }
            }
        }
        return String(sum, radix: 16).leftPadded(to: 16)
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        String(repeating: "0", count: max(length - count, 0)) + self
    }
}
