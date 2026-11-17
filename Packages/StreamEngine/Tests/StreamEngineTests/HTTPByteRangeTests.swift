@testable import StreamEngine
import Testing

@Suite("HTTP Range header resolution")
struct HTTPByteRangeTests {
    private let length: Int64 = 1000

    @Test("Satisfiable single ranges", arguments: [
        ("bytes=0-499", 0, 499),
        ("bytes=500-999", 500, 999),
        ("bytes=0-0", 0, 0),
        ("bytes=999-", 999, 999),
        ("bytes=200-", 200, 999),
        ("bytes=900-5000", 900, 999),
        ("bytes=-100", 900, 999),
        ("bytes=-5000", 0, 999),
        ("BYTES=10-20", 10, 20),
        ("bytes = 10 - 20", 10, 20),
    ] as [(String, Int64, Int64)])
    func partial(header: String, first: Int64, last: Int64) {
        #expect(HTTPByteRange.resolve(header: header, resourceLength: length) == .partial(first ... last))
    }

    @Test("Ranges that start past the end are unsatisfiable", arguments: [
        "bytes=1000-",
        "bytes=1000-1200",
        "bytes=-0",
    ])
    func unsatisfiable(header: String) {
        #expect(HTTPByteRange.resolve(header: header, resourceLength: length) == .unsatisfiable)
    }

    @Test("Missing, malformed or multi-range headers fall back to the full resource", arguments: [
        nil,
        "",
        "bytes",
        "bytes=",
        "bytes=abc-def",
        "bytes=500-100",
        "bytes=0-10,20-30",
        "bytes=+5-10",
        "bytes=5",
        "items=0-10",
        "bytes=99999999999999999999-",
    ] as [String?])
    func full(header: String?) {
        #expect(HTTPByteRange.resolve(header: header, resourceLength: length) == .full)
    }

    @Test("An empty resource has no satisfiable range")
    func emptyResource() {
        #expect(HTTPByteRange.resolve(header: "bytes=0-", resourceLength: 0) == .unsatisfiable)
        #expect(HTTPByteRange.resolve(header: "bytes=-10", resourceLength: 0) == .unsatisfiable)
        #expect(HTTPByteRange.resolve(header: nil, resourceLength: 0) == .full)
    }

    @Test("Offsets beyond 4 GB are handled")
    func largeFile() {
        let big: Int64 = 60_000_000_000
        #expect(
            HTTPByteRange.resolve(header: "bytes=50000000000-", resourceLength: big)
                == .partial(50_000_000_000 ... big - 1)
        )
    }
}
