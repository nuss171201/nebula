import MediaCore
import SwiftUI

/// A word on a stream's row saying what kind of picture or sound it has.
enum StreamBadge: String, Hashable, Sendable {
    case dolbyVision = "DV"
    case hdr = "HDR"
    case atmos = "Atmos"
    case uhd = "4K"
    case fullHD = "1080p"
    case hd = "720p"
    case qhd = "1440p"
    case sd = "SD"

    /// The picture quality, then what the stream's text says of high dynamic range and of
    /// sound that comes from above. Read from text add-ons write as they please: a badge that
    /// is missing means nothing.
    static func badges(for choice: StreamChoice) -> [StreamBadge] {
        let text = [choice.stream.name, choice.stream.details, choice.stream.behaviorHints.filename].compactMap(\.self).joined(separator: " ")
        var badges: [StreamBadge] = []
        switch choice.quality {
        case .uhd4K: badges.append(.uhd)
        case .qhd1440: badges.append(.qhd)
        case .hd1080: badges.append(.fullHD)
        case .hd720: badges.append(.hd)
        case .sd: badges.append(.sd)
        case nil: break
        }
        return badges + extras(in: text)
    }

    static func extras(in text: String) -> [StreamBadge] {
        let lowered = text.lowercased()
        func mentions(_ pattern: Regex<Substring>) -> Bool {
            lowered.contains(pattern.wordBoundaryKind(.simple))
        }
        var badges: [StreamBadge] = []
        if mentions(/\b(?:dv|dovi|dolby\W?vision)\b/) {
            badges.append(.dolbyVision)
        }
        if mentions(/\bhdr(?:10)?\+?/) {
            badges.append(.hdr)
        }
        if mentions(/\batmos\b/) {
            badges.append(.atmos)
        }
        return badges
    }

    var isQuality: Bool {
        switch self {
        case .uhd, .fullHD, .hd, .qhd, .sd: true
        case .dolbyVision, .hdr, .atmos: false
        }
    }
}

struct StreamBadgeView: View {
    let badge: StreamBadge

    var body: some View {
        Text(badge.rawValue)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.cardStroke(), lineWidth: badge.isQuality ? 0 : 1))
            .accessibilityHidden(true)
    }

    private var foreground: AnyShapeStyle {
        switch badge {
        case .uhd: AnyShapeStyle(Color.black.opacity(0.85))
        case .fullHD, .qhd: AnyShapeStyle(.white)
        default: AnyShapeStyle(.secondary)
        }
    }

    private var background: AnyShapeStyle {
        switch badge {
        // Gold for the best picture there is.
        case .uhd: AnyShapeStyle(LinearGradient(
                colors: [Color(red: 1, green: 0.84, blue: 0.4), Color(red: 0.96, green: 0.65, blue: 0.2)],
                startPoint: .top,
                endPoint: .bottom
            ))
        case .fullHD, .qhd: AnyShapeStyle(Color.accentColor.opacity(0.85))
        default: AnyShapeStyle(Theme.cardFill())
        }
    }
}
