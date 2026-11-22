import MediaCore
import SwiftUI

/// The banner at the top of Home: one featured title at a time over its backdrop, with Play,
/// the library button and a way to its page. It turns to the next title by itself, but only
/// while its window is the one in use and nobody is pointing at it.
struct FeaturedBanner: View {
    let model: FeaturedModel
    let library: LibraryCenter
    /// Opens the title's page and plays it.
    let play: (MetaItem) -> Void

    @Environment(\.openTitle) private var openTitle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverOn
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.displayScale) private var displayScale
    @State private var isHovered = false

    /// The banner takes this share of the page's height, within these bounds: enough to be the
    /// first thing seen, with the first row still showing under it.
    static let shareOfPage: CGFloat = 0.62
    static let heights: ClosedRange<CGFloat> = 340 ... 560
    /// The size the title's page asks for its backdrop in, so that the picture is fetched and
    /// decoded once for both.
    static let backdropPointSize: CGFloat = 1100

    private var turnsByItself: Bool {
        FeaturedModel.turnsByItself(
            count: model.items.count,
            isPointedAt: isHovered,
            reducesMotion: reduceMotion,
            isReadAloud: isVoiceOverOn,
            isInKeyWindow: activeState == .key
        )
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(.quaternary)
            if let item = model.current {
                FeaturedSlide(
                    item: item,
                    isSaved: model.isSaved(item),
                    play: { play(item) },
                    toggleSaved: { Task { await model.toggleSaved(item, in: library) } },
                    moreInfo: { openTitle(item) }
                )
                .id(FeaturedModel.key(item))
                .transition(.opacity)
            }
            if model.items.count > 1 {
                pager
            }
        }
        .containerRelativeFrame(.vertical) { pageHeight, _ in
            min(max(pageHeight * Self.shareOfPage, Self.heights.lowerBound), Self.heights.upperBound)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: model.index)
        .onHover { isHovered = $0 }
        .task(id: turnsByItself) {
            await turn()
        }
        .task(id: "\(library.revision)|\(model.items.map(\.id).joined(separator: ","))") {
            await model.refreshSaved(from: library)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Featured")
    }

    /// Shows the next title every few seconds, having fetched its picture first so that it is
    /// there when the banner turns.
    private func turn() async {
        guard turnsByItself else { return }
        while !Task.isCancelled {
            if let url = model.next?.background, let pipeline {
                _ = try? await pipeline.image(for: url, maxPixelSize: Int((Self.backdropPointSize * displayScale).rounded(.up)))
            }
            try? await Task.sleep(for: FeaturedModel.turnInterval)
            guard !Task.isCancelled else { return }
            model.advance()
        }
    }

    /// Previous, one dot per title, next.
    private var pager: some View {
        HStack(spacing: 4) {
            pagerButton("chevron.left", label: "Previous Featured Title", action: model.goBack)
            ForEach(Array(model.items.enumerated()), id: \.offset) { position, item in
                Button {
                    model.show(position)
                } label: {
                    Capsule()
                        .fill(.white.opacity(position == model.index ? 0.95 : 0.4))
                        .frame(width: position == model.index ? 18 : 7, height: 7)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(item.name)")
                .accessibilityAddTraits(position == model.index ? .isSelected : [])
            }
            pagerButton("chevron.right", label: "Next Featured Title", action: model.advance)
        }
        .padding(.horizontal, 10)
        .background(.black.opacity(0.35), in: Capsule())
        .padding(.trailing, 24)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func pagerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// One featured title: its backdrop, and over it what it is and what can be done with it.
private struct FeaturedSlide: View {
    let item: MetaItem
    let isSaved: Bool
    let play: () -> Void
    let toggleSaved: () -> Void
    let moreInfo: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The picture fills the banner and is cut to it, from the top (where the faces are).
            // In an overlay, so that its own size, which is larger than the banner's, moves nothing.
            Color.clear
                .overlay(alignment: .top) {
                    RemoteImage(url: item.background, maxPointSize: FeaturedBanner.backdropPointSize, placeholderSystemImage: "photo")
                }
                .clipped()
                .overlay { shade }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                FeaturedTitle(item: item)
                let facts = FeaturedModel.facts(for: item)
                if !facts.isEmpty {
                    Text(facts.joined(separator: "  ·  "))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                if let description = item.description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                buttons
                    .padding(.top, 4)
            }
            .frame(maxWidth: 540, alignment: .leading)
            .padding(.leading, 28)
            .padding(.bottom, 30)
            // The picture is dark under the words whatever the app's appearance is.
            .environment(\.colorScheme, .dark)
        }
    }

    /// Darkens the picture where the words are: the left, and the bottom.
    private var shade: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.8), location: 0),
                    .init(color: .black.opacity(0.45), location: 0.4),
                    .init(color: .clear, location: 0.75),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(ProminentPillButtonStyle())
            .accessibilityHint(item.type == .series ? "Plays the next episode to watch" : "Plays this title")

            Button(action: toggleSaved) {
                Label(isSaved ? "In Library" : "Add to Library", systemImage: isSaved ? "checkmark" : "plus")
                    .padding(.vertical, 3)
            }
            .buttonStyle(BannerPillButtonStyle())
            .accessibilityHint(isSaved ? "Removes this title from your library" : "Saves this title to your library")

            Button(action: moreInfo) {
                Label("More Info", systemImage: "info.circle")
                    .padding(.vertical, 3)
            }
            .buttonStyle(BannerPillButtonStyle())
            .accessibilityHint("Opens this title's page")
        }
    }
}

/// The title as its own logo when the catalog has one and it loads, in words otherwise.
private struct FeaturedTitle: View {
    let item: MetaItem

    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.displayScale) private var displayScale
    @State private var logo = Logo.pending

    private enum Logo {
        /// Not known yet whether there is one: nothing is shown, so words are not flashed first.
        case pending
        case image(CGImage)
        case none
    }

    private static let width: CGFloat = 360
    private static let height: CGFloat = 110

    var body: some View {
        Group {
            switch logo {
            case .pending:
                Color.clear
            case let .image(image):
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            case .none:
                Text(item.name)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            }
        }
        .frame(maxWidth: Self.width, maxHeight: Self.height, alignment: .bottomLeading)
        .frame(height: Self.height, alignment: .bottomLeading)
        .accessibilityElement()
        .accessibilityLabel(FeaturedModel.spokenSummary(for: item))
        .accessibilityAddTraits(.isHeader)
        .task(id: item.logo) {
            await load()
        }
    }

    private func load() async {
        guard let url = item.logo, let pipeline else {
            logo = .none
            return
        }
        let size = Int((Self.width * displayScale).rounded(.up))
        var image = pipeline.cachedImage(for: url, maxPixelSize: size)
        if image == nil {
            image = try? await pipeline.image(for: url, maxPixelSize: size)
        }
        guard !Task.isCancelled else { return }
        // A logo drawn for a light page cannot be read on the darkened picture: words instead.
        logo = image.flatMap { LogoLegibility.isReadableOnDark($0) ? .image($0) : nil } ?? .none
    }
}

/// Whether a title's logo can be read where the banner puts it, on a darkened picture.
enum LogoLegibility {
    /// Logos lighter than this, on average, are shown; darker ones give way to words.
    static let readableFrom = 0.45

    static func isReadableOnDark(_ image: CGImage) -> Bool {
        (brightness(of: image) ?? 0) >= readableFrom
    }

    /// How light the logo's visible parts are on average, from 0 (black) to 1 (white).
    /// `nil` if nothing of it is visible. Measured on a copy a few pixels across.
    static func brightness(of image: CGImage) -> Double? {
        let width = 32
        let height = 16
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)
        var light = 0.0
        var coverage = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            // The colours are already multiplied by how much of the pixel the logo covers.
            light += (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255
            coverage += Double(pixels[index + 3]) / 255
        }
        return coverage > 0.5 ? light / coverage : nil
    }
}
