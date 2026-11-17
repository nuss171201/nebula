/// How the local streaming server should answer a request's `Range` header.
public enum HTTPRangeResolution: Equatable, Sendable {
    /// No usable range: answer `200 OK` with the whole resource.
    case full
    /// Answer `206 Partial Content` with these inclusive byte offsets.
    case partial(ClosedRange<Int64>)
    /// Answer `416 Range Not Satisfiable`.
    case unsatisfiable
}

/// Parses a single-range `Range: bytes=…` header as defined in RFC 9110 §14.
///
/// The player only ever asks for one range at a time. A multi-range or syntactically
/// invalid header is ignored, which the RFC permits, and the full resource is served.
public enum HTTPByteRange {
    public static func resolve(header: String?, resourceLength: Int64) -> HTTPRangeResolution {
        guard let header, let spec = parse(header) else { return .full }

        switch spec {
        case let .suffix(count):
            guard count > 0, resourceLength > 0 else { return .unsatisfiable }
            return .partial(max(0, resourceLength - count) ... resourceLength - 1)

        case let .from(first):
            guard first < resourceLength else { return .unsatisfiable }
            return .partial(first ... resourceLength - 1)

        case let .closed(first, last):
            guard first < resourceLength else { return .unsatisfiable }
            return .partial(first ... min(last, resourceLength - 1))
        }
    }

    /// The three shapes a single byte range can take.
    private enum Spec {
        /// `bytes=-N`: the final N bytes.
        case suffix(Int64)
        /// `bytes=N-`: from offset N to the end.
        case from(Int64)
        /// `bytes=N-M`: inclusive offsets, with `N <= M`.
        case closed(Int64, Int64)
    }

    /// Returns `nil` for anything that is not exactly one well-formed byte range.
    private static func parse(_ header: String) -> Spec? {
        let parts = header.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].trimmingWhitespace().lowercased() == "bytes" else { return nil }

        let range = parts[1].trimmingWhitespace()
        guard !range.contains(","), let dash = range.firstIndex(of: "-") else { return nil }

        let firstText = range[..<dash].trimmingWhitespace()
        let lastText = range[range.index(after: dash)...].trimmingWhitespace()

        if firstText.isEmpty {
            return parseOffset(lastText).map(Spec.suffix)
        }
        guard let first = parseOffset(firstText) else { return nil }
        if lastText.isEmpty {
            return .from(first)
        }
        guard let last = parseOffset(lastText), first <= last else { return nil }
        return .closed(first, last)
    }

    /// Accepts only plain ASCII digits; rejects signs, whitespace and overflow.
    private static func parseOffset(_ text: Substring) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int64(text)
    }
}

private extension StringProtocol where SubSequence == Substring {
    func trimmingWhitespace() -> Substring {
        var slice = self[...]
        while let first = slice.first, first == " " || first == "\t" {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == " " || last == "\t" {
            slice = slice.dropLast()
        }
        return slice
    }
}
