import SwiftUI

extension EnvironmentValues {
    /// The shared artwork loader. `nil` in previews and tests, where placeholders are shown.
    @Entry var imagePipeline: ImagePipeline?
}

/// Artwork from a URL, decoded at the size it is displayed and filling its frame.
/// Give it a fixed frame; it never affects layout while loading.
struct RemoteImage: View {
    let url: URL?
    /// The longest edge of the frame this image is shown in, in points.
    let maxPointSize: CGFloat
    var placeholderSystemImage = "photo"

    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: LoadedImage?

    private struct LoadedImage {
        let url: URL
        let image: CGImage
    }

    private var maxPixelSize: Int {
        Int((maxPointSize * displayScale).rounded(.up))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let loaded, loaded.url == url {
                Image(decorative: loaded.image, scale: displayScale)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: placeholderSystemImage)
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url, let pipeline else {
            loaded = nil
            return
        }
        if let cached = pipeline.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            loaded = LoadedImage(url: url, image: cached)
            return
        }
        guard let image = try? await pipeline.image(for: url, maxPixelSize: maxPixelSize), !Task.isCancelled else {
            return
        }
        withAnimation(.easeOut(duration: 0.15)) {
            loaded = LoadedImage(url: url, image: image)
        }
    }
}
