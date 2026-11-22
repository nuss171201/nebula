import MediaCore
import SwiftUI

/// A title's artwork and name; clicking it opens the detail page.
struct PosterCard: View {
    enum Sizing {
        /// Fixed height; the width follows the artwork's shape. For horizontal rows.
        case height(CGFloat)
        /// Fills the width it is given; the height follows the shape. For grids.
        case flexibleWidth
    }

    let item: MetaItem
    var sizing: Sizing = .height(PosterCard.rowArtworkHeight)

    static let rowArtworkHeight: CGFloat = 210
    /// Artwork plus the two text lines below it.
    static let rowHeight: CGFloat = rowArtworkHeight + 46

    @State private var isHovered = false

    var body: some View {
        NavigationLink(value: MediaRoute(item: item)) {
            VStack(alignment: .leading, spacing: 6) {
                artwork
                    // The picture grows inside its frame, so the card keeps its place in the grid.
                    .scaleEffect(isHovered ? 1.06 : 1)
                    .clipShape(.rect(cornerRadius: Theme.artworkRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.artworkRadius, style: .continuous)
                            .strokeBorder(isHovered ? Color.accentColor.opacity(0.9) : .white.opacity(0.08), lineWidth: isHovered ? 2 : 1)
                    }
                    .shadow(color: Color.accentColor.opacity(isHovered ? 0.45 : 0), radius: 14, y: 4)
                    .animation(Theme.hover, value: isHovered)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                    Text(item.releaseInfo ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // Long titles must truncate, not widen the card past its artwork.
            .frame(width: fixedWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityText)
        .help(item.name)
    }

    /// The card's width when it is driven by a fixed artwork height; `nil` in grids.
    private var fixedWidth: CGFloat? {
        if case let .height(height) = sizing {
            height * item.posterShape.aspectRatio
        } else {
            nil
        }
    }

    @ViewBuilder private var artwork: some View {
        let ratio = item.posterShape.aspectRatio
        switch sizing {
        case let .height(height):
            RemoteImage(url: item.poster, maxPointSize: max(height, height * ratio), placeholderSystemImage: "film")
                .frame(width: height * ratio, height: height)
        case .flexibleWidth:
            Color.clear
                .aspectRatio(ratio, contentMode: .fit)
                .overlay {
                    RemoteImage(url: item.poster, maxPointSize: 280, placeholderSystemImage: "film")
                }
        }
    }

    private var accessibilityText: String {
        [item.name, item.releaseInfo].compactMap(\.self).joined(separator: ", ")
    }
}

/// An inline failure message with a way to try again.
struct RetryMessage: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Button("Try Again", action: retry)
        }
    }
}
