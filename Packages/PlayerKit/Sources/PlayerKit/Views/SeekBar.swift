import SwiftUI

/// Conversions between positions in time and positions along the bar.
enum SeekBarGeometry {
    /// The time under a point `x` along a bar of `width`, clamped to the file.
    static func time(atX x: CGFloat, width: CGFloat, duration: Double) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * duration
    }

    static func x(for time: Double, width: CGFloat, duration: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1)) * width
    }

    /// Where to put a preview of `previewWidth` centred on `x` without leaving the bar.
    static func previewOffset(centredAt x: CGFloat, previewWidth: CGFloat, barWidth: CGFloat) -> CGFloat {
        let ideal = x - previewWidth / 2
        return min(max(ideal, 0), max(barWidth - previewWidth, 0))
    }
}

/// The seek bar: progress, buffered range, chapter marks and A-B loop marks; a preview
/// with the time, chapter and a still frame while hovering; drag or click to seek.
struct SeekBar: View {
    let model: PlayerModel
    let chrome: PlayerChromeModel
    /// Whether hovering shows a still frame, chapter and time above the bar. Off in the small
    /// windows, which have no room above the bar.
    var showsPreview = true

    @State private var isDragging = false
    @State private var preview: CGImage?

    private static let barHeight: CGFloat = 4
    private static let hitHeight: CGFloat = 22
    private static let previewWidth: CGFloat = 176

    private var duration: Double {
        model.state.duration ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let hoverX = chrome.seekHoverFraction.map { CGFloat($0) * width }
            ZStack(alignment: .leading) {
                track(width: width, isLively: hoverX != nil || isDragging)
                marks(width: width)
                if hoverX != nil || isDragging {
                    Circle()
                        .fill(.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: Color.accentColor.opacity(0.9), radius: 6)
                        .offset(x: SeekBarGeometry.x(for: model.displayPosition, width: width, duration: duration) - 6.5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: hoverX != nil || isDragging)
            .frame(height: Self.hitHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        chrome.seekHoverFraction = fraction(value.location.x, of: width)
                        model.scrubPosition = SeekBarGeometry.time(atX: value.location.x, width: width, duration: duration)
                    }
                    .onEnded { _ in
                        isDragging = false
                        model.commitScrub()
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    chrome.seekHoverFraction = fraction(point.x, of: width)
                case .ended:
                    if !isDragging {
                        chrome.seekHoverFraction = nil
                    }
                }
            }
            // The preview's bottom edge sits a little above the bar's top edge.
            .overlay(alignment: .bottomLeading) {
                if showsPreview, let hoverX {
                    let time = SeekBarGeometry.time(atX: hoverX, width: width, duration: duration)
                    SeekPreview(time: time, chapter: model.state.chapter(at: time)?.title, image: preview, width: Self.previewWidth)
                        .offset(
                            x: SeekBarGeometry.previewOffset(centredAt: hoverX, previewWidth: Self.previewWidth, barWidth: width),
                            y: -(Self.hitHeight + 6)
                        )
                        .allowsHitTesting(false)
                        .task(id: PreviewRequest(step: previewKey(for: time), isAvailable: model.canPreviewFrames)) {
                            preview = await model.thumbnail(at: time) ?? preview
                        }
                }
            }
        }
        .frame(height: Self.hitHeight)
        .opacity(duration > 0 && model.state.hasMedia ? 1 : 0.4)
        .allowsHitTesting(duration > 0 && model.state.hasMedia)
        .onChange(of: model.source) {
            preview = nil
        }
        .accessibilityRepresentation {
            Slider(
                value: Binding {
                    model.displayPosition
                } set: { position in
                    model.seek(to: position)
                },
                in: 0 ... max(duration, 1)
            )
            .accessibilityLabel("Position")
            .accessibilityValue(PlaybackTime.format(model.displayPosition))
        }
    }

    private func fraction(_ x: CGFloat, of width: CGFloat) -> Double {
        width > 0 ? Double(min(max(x / width, 0), 1)) : 0
    }

    /// Changes only when the pointer moves into another preview step, so frames are not requested per pixel.
    private func previewKey(for time: Double) -> Int {
        Int(time / PlayerModel.thumbnailStep(duration: max(duration, 1)))
    }

    /// - Parameter isLively: The pointer is on the bar: it thickens, to be easier to aim at.
    private func track(width: CGFloat, isLively: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.22))
            if let buffered = model.bufferedFraction {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: width * buffered)
            }
            Capsule()
                .fill(LinearGradient(colors: [Color.accentColor, .white], startPoint: .leading, endPoint: .trailing))
                .frame(width: SeekBarGeometry.x(for: model.displayPosition, width: width, duration: duration))
        }
        .frame(height: isLively ? Self.barHeight + 2 : Self.barHeight)
    }

    /// Chapter starts as gaps in the bar, and the A-B loop's ends as coloured ticks.
    @ViewBuilder private func marks(width: CGFloat) -> some View {
        ForEach(model.state.chapters.dropFirst()) { chapter in
            Rectangle()
                .fill(.black.opacity(0.75))
                .frame(width: 2, height: Self.barHeight + 2)
                .offset(x: SeekBarGeometry.x(for: chapter.start, width: width, duration: duration) - 1)
        }
        ForEach(loopMarks, id: \.self) { time in
            Rectangle()
                .fill(.orange)
                .frame(width: 2, height: 12)
                .offset(x: SeekBarGeometry.x(for: time, width: width, duration: duration) - 1)
        }
    }

    private var loopMarks: [Double] {
        switch model.abLoop {
        case .off: []
        case let .startMarked(start): [start]
        case let .looping(start, end): [start, end]
        }
    }
}

/// Identifies a preview request: which step of the file, and whether frames can be made yet
/// (so a preview asked for while the file was still opening is asked for again once they can).
private struct PreviewRequest: Hashable {
    let step: Int
    let isAvailable: Bool
}

/// What floats above the seek bar under the pointer.
private struct SeekPreview: View {
    let time: Double
    let chapter: String?
    let image: CGImage?
    let width: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            if let image, image.width > 0 {
                // An explicit height: the preview is laid out in the seek bar's own (short) space,
                // where a merely "fitting" image is given no height at all.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: width, height: (width * CGFloat(image.height) / CGFloat(image.width)).rounded())
                    .clipShape(.rect(cornerRadius: 4))
            }
            if let chapter {
                Text(chapter)
                    .font(.caption)
                    .lineLimit(1)
            }
            Text(PlaybackTime.format(time))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(6)
        .frame(width: width + 12)
        // As tall as its contents, whatever height the seek bar offers.
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .offset(x: -6)
    }
}
