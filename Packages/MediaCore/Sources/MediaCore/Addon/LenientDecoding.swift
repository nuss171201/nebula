import Foundation

// Add-ons are written by many people and are loose about JSON types: numbers arrive
// as strings, single values where arrays are expected, empty strings for "missing".
// These helpers read what is usable and never fail the surrounding object.

/// Decodes `Wrapped`, or records `nil` instead of failing the surrounding array.
struct Failable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// A non-empty string. Numbers are converted; empty or whitespace-only strings read as `nil`.
    func lenientString(_ key: Key) -> String? {
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let integer = try? decodeIfPresent(Int.self, forKey: key) {
            return String(integer)
        }
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return String(number)
        }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let integer = try? decodeIfPresent(Int.self, forKey: key) {
            return integer
        }
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(exactly: number.rounded())
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func lenientInt64(_ key: Key) -> Int64? {
        if let integer = try? decodeIfPresent(Int64.self, forKey: key) {
            return integer
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return number
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Double(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
    }

    /// Any absolute URL. Protocol-relative values (`//host/path`) are read as https.
    func lenientURL(_ key: Key) -> URL? {
        guard var text = lenientString(key) else { return nil }
        if text.hasPrefix("//") {
            text = "https:" + text
        }
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }

    /// An http(s) URL only. Used for anything the app fetches on its own (images),
    /// so an add-on cannot point the app at `file:` or other local schemes.
    func lenientWebURL(_ key: Key) -> URL? {
        guard let url = lenientURL(key), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil
        else { return nil }
        return url
    }

    /// The decodable elements of an array, skipping any that are malformed.
    func lenientArray<Element: Decodable>(_ key: Key, of _: Element.Type = Element.self) -> [Element] {
        let elements = try? decodeIfPresent([Failable<Element>].self, forKey: key)
        return elements?.compactMap(\.value) ?? []
    }

    /// An array of non-empty strings; a single string is read as a one-element array.
    func lenientStrings(_ key: Key) -> [String] {
        let list: [String] = if let many = try? decodeIfPresent([Failable<String>].self, forKey: key) {
            many.compactMap(\.value)
        } else if let single = try? decodeIfPresent(String.self, forKey: key) {
            [single]
        } else {
            []
        }
        return list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// An ISO 8601 timestamp, with or without fractional seconds, or a plain `yyyy-MM-dd` date.
    func lenientDate(_ key: Key) -> Date? {
        guard let text = lenientString(key) else { return nil }
        return LenientDate.parse(text)
    }
}

enum LenientDate {
    static func parse(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day())
    }
}

extension KeyedDecodingContainer {
    /// Like `lenientString`, for text that is shown to people: catalogs sometimes send it with
    /// HTML character references left in ("O&apos;Dea"), which are turned back into characters.
    func lenientText(_ key: Key) -> String? {
        lenientString(key)?.decodingCharacterReferences()
    }

    func lenientTexts(_ key: Key) -> [String] {
        lenientStrings(key).map { $0.decodingCharacterReferences() }
    }
}

extension String {
    private static let namedReferences: [String: Character] = [
        "amp": "&", "apos": "'", "quot": "\"", "lt": "<", "gt": ">", "nbsp": "\u{A0}",
    ]

    /// Replaces the common HTML character references (`&amp;`, `&apos;`, `&#39;`, `&#x27;`)
    /// with the characters they stand for. Anything unrecognised is left as it is.
    func decodingCharacterReferences() -> String {
        guard contains("&") else { return self }
        var result = ""
        var rest = self[...]
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let tail = rest[ampersand...]
            guard let semicolon = tail.prefix(10).firstIndex(of: ";") else {
                result += "&"
                rest = tail.dropFirst()
                continue
            }
            let name = tail[tail.index(after: ampersand) ..< semicolon]
            let character: Character? = if name.hasPrefix("#x") || name.hasPrefix("#X") {
                UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(Character.init)
            } else if name.hasPrefix("#") {
                UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map(Character.init)
            } else {
                Self.namedReferences[String(name)]
            }
            if let character {
                result.append(character)
                rest = tail[tail.index(after: semicolon)...]
            } else {
                result += "&"
                rest = tail.dropFirst()
            }
        }
        return result + rest
    }
}
