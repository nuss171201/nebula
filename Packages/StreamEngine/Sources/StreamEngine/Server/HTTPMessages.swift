import Foundation

/// The first line and headers of a request, as much as the stream server needs.
struct HTTPRequestHead: Equatable {
    var method: String
    /// The path as sent, still percent-encoded, without any query.
    var path: String
    /// Header names in lower case.
    var headers: [String: String]

    /// The longest request head accepted. The player's requests are a few hundred bytes.
    static let maximumLength = 16 * 1024
    static let terminator = Data("\r\n\r\n".utf8)

    /// Parses a head (everything up to, not including, the blank line). `nil` if it is not HTTP/1.x.
    static func parse(_ data: Data) -> HTTPRequestHead? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/") else { return nil }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers[name] = value
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return HTTPRequestHead(method: String(requestLine[0]), path: path, headers: headers)
    }

    /// Whether the request was addressed to this machine by its loopback name. A web page
    /// elsewhere that tricks a browser into calling the server arrives under its own host name.
    func isAddressedToLoopback(port: Int) -> Bool {
        guard let host = headers["host"]?.lowercased() else { return false }
        return ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host)
    }
}

/// The status line and headers of a response.
struct HTTPResponseHead: Equatable {
    var status: Int
    var headers: [(name: String, value: String)]

    static func == (lhs: HTTPResponseHead, rhs: HTTPResponseHead) -> Bool {
        lhs.status == rhs.status && lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        default: "Error"
        }
    }

    var serialized: Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        for header in headers {
            text += "\(header.name): \(header.value)\r\n"
        }
        return Data((text + "\r\n").utf8)
    }

    /// A response with no body.
    static func empty(_ status: Int, extra: [(name: String, value: String)] = []) -> HTTPResponseHead {
        HTTPResponseHead(status: status, headers: extra + [("Content-Length", "0"), ("Connection", "close")])
    }

    /// The head for serving a resource, and the bytes of it to send (`nil` for none).
    static func forResource(
        size: Int64,
        contentType: String,
        rangeHeader: String?
    ) -> (head: HTTPResponseHead, body: ClosedRange<Int64>?) {
        let common: [(name: String, value: String)] = [
            ("Accept-Ranges", "bytes"),
            ("Content-Type", contentType),
            // The bytes are on their way to a player on this machine; nothing should keep a copy.
            ("Cache-Control", "no-store"),
            ("Connection", "close"),
        ]
        switch HTTPByteRange.resolve(header: rangeHeader, resourceLength: size) {
        case .full:
            let head = HTTPResponseHead(status: 200, headers: [("Content-Length", String(size))] + common)
            return (head, size > 0 ? 0 ... size - 1 : nil)
        case let .partial(range):
            let headers: [(name: String, value: String)] = [
                ("Content-Length", String(range.count)),
                ("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"),
            ]
            return (HTTPResponseHead(status: 206, headers: headers + common), range)
        case .unsatisfiable:
            return (.empty(416, extra: [("Content-Range", "bytes */\(size)")]), nil)
        }
    }
}

enum StreamContentType {
    private static let known: [String: String] = [
        "mkv": "video/x-matroska", "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
        "avi": "video/x-msvideo", "ts": "video/mp2t", "m2ts": "video/mp2t", "mpg": "video/mpeg", "mpeg": "video/mpeg",
        "wmv": "video/x-ms-wmv", "flv": "video/x-flv", "ogv": "video/ogg",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "flac": "audio/flac", "ogg": "audio/ogg", "opus": "audio/ogg",
        "wav": "audio/wav", "mka": "audio/x-matroska",
        "srt": "application/x-subrip", "vtt": "text/vtt", "ass": "text/x-ass",
    ]

    static func forFile(named name: String) -> String {
        known[(name as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
