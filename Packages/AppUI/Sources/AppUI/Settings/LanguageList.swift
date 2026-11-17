import Foundation
import PlayerKit

/// Turns what a person types for "my languages" into language codes and back into names.
public enum LanguageList {
    /// Codes (`en`, `eng`, `pt-BR`) and names (`Japanese`, `français`) separated by commas,
    /// as two-letter codes where the language has one, in the order typed, without repeats.
    /// What is not recognised is left out.
    public static func parse(_ text: String, locale: Locale = .current) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .compactMap { code(for: $0.trimmingCharacters(in: .whitespaces), locale: locale) }
            .filter { seen.insert($0).inserted }
    }

    /// "English, Japanese" for `["en", "ja"]`.
    public static func names(of codes: [String], locale: Locale = .current) -> String {
        codes.map { locale.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: ", ")
    }

    static func code(for word: String, locale: Locale) -> String? {
        guard !word.isEmpty else { return nil }
        let lowered = word.lowercased()
        if let code = names(in: locale)[lowered] ?? englishNames[lowered] {
            return code
        }
        // A code, with or without a region. Only letters, so that a stray word is not read as one.
        let head = lowered.split(separator: "-").first.map(String.init) ?? lowered
        guard (2 ... 3).contains(head.count), head.allSatisfy({ $0.isASCII && $0.isLetter }),
              let code = LanguageMatcher.canonical(lowered), isKnown(code)
        else { return nil }
        return code
    }

    private static func isKnown(_ code: String) -> Bool {
        englishLocale.localizedString(forLanguageCode: code) != nil
    }

    private static let englishLocale = Locale(identifier: "en")
    private static let englishNames = names(in: englishLocale)
    private static let cache = NameCache()

    /// Lower-cased language names in a locale, to two-letter codes where there is one.
    private static func names(in locale: Locale) -> [String: String] {
        cache.names(for: locale) {
            var names: [String: String] = [:]
            for language in Locale.LanguageCode.isoLanguageCodes {
                let identifier = language.identifier
                guard let code = LanguageMatcher.canonical(identifier), let name = locale.localizedString(forLanguageCode: identifier) else { continue }
                // Two-letter codes are listed with their three-letter twins; the first one in wins.
                if names[name.lowercased()] == nil {
                    names[name.lowercased()] = code
                }
            }
            return names
        }
    }

    private final class NameCache: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [String: [String: String]] = [:]

        func names(for locale: Locale, make: () -> [String: String]) -> [String: String] {
            lock.withLock {
                if let table = tables[locale.identifier] {
                    return table
                }
                let table = make()
                tables[locale.identifier] = table
                return table
            }
        }
    }
}
