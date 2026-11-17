import AppKit
import QuartzCore
import SwiftUI

/// Where the engine's fixed-size canvas goes inside a view of any size.
///
/// The engine draws the video aspect-fitted and centred inside the canvas, at the
/// canvas's resolution. The view then shows the canvas scaled so that the video's
/// rectangle (not the whole canvas) is aspect-fitted to the view.
enum CanvasGeometry {
    /// Longest canvas edge in pixels. Larger screens show the canvas scaled up.
    static let maximumEdge: CGFloat = 3840
    static let fallbackSize = CGSize(width: 2560, height: 1440)

    /// A canvas matching a screen's pixel size: even dimensions, capped at `maximumEdge`.
    static func canvasSize(forScreenPixels screen: CGSize) -> CGSize {
        guard screen.width >= 16, screen.height >= 16 else { return fallbackSize }
        let shrink = min(1, maximumEdge / max(screen.width, screen.height))
        func even(_ value: CGFloat) -> CGFloat {
            max((value * shrink / 2).rounded(.down) * 2, 2)
        }
        return CGSize(width: even(screen.width), height: even(screen.height))
    }

    /// The rectangle the engine draws the video into, in canvas pixels.
    static func videoRect(canvas: CGSize, video: CGSize?) -> CGRect {
        guard let video, video.width > 0, video.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let fit = min(canvas.width / video.width, canvas.height / video.height)
        let size = CGSize(width: video.width * fit, height: video.height * fit)
        return CGRect(
            x: (canvas.width - size.width) / 2,
            y: (canvas.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// View points per canvas pixel, so that the video's rectangle is aspect-fitted to the view.
    static func scale(canvas: CGSize, video: CGSize?, view: CGSize) -> CGFloat {
        let rect = videoRect(canvas: canvas, video: video)
        guard rect.width > 0, rect.height > 0, view.width > 0, view.height > 0 else { return 1 }
        return min(view.width / rect.width, view.height / rect.height)
    }
}

/// The layer the engine renders into.
final class CanvasLayer: CAMetalLayer {
    /// The Vulkan-on-Metal layer under the engine briefly sets the drawable size to 1×1 when it
    /// tears down a swapchain. Left alone, that size can stick and the next file is laid out for
    /// a one-pixel surface, so degenerate sizes are ignored. (The quirk and this remedy are
    /// described in https://github.com/mpv-player/mpv/pull/13651.)
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

/// The view video is shown in.
///
/// The playback engine renders, through Vulkan on Metal, into a canvas layer whose size
/// never changes. This build of the engine has no way to be told that its surface was
/// resized (it would keep laying the picture out for the old size), so instead of resizing
/// the surface this view scales the canvas with Core Animation. Resizing the window and
/// going full screen are therefore free and smooth; the cost is that the picture is always
/// rendered at screen resolution and scaled down for smaller windows.
public final class PlayerSurfaceView: NSView {
    let canvasLayer: CanvasLayer
    /// The canvas size in pixels. Fixed for the life of the view.
    let canvasSize: CGSize

    /// The video's display size, once known. Decides which part of the canvas is shown.
    var videoSize: CGSize? {
        didSet {
            if videoSize != oldValue {
                layoutCanvas()
            }
        }
    }

    public init() {
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let points = screen?.frame.size ?? .zero
        canvasSize = CanvasGeometry.canvasSize(
            forScreenPixels: CGSize(width: points.width * scale, height: points.height * scale)
        )

        let canvas = CanvasLayer()
        canvas.isOpaque = true
        canvas.framebufferOnly = true
        canvas.backgroundColor = CGColor(gray: 0, alpha: 1)
        // One layer unit is one canvas pixel; the transform below maps it to the view.
        canvas.contentsScale = 1
        canvas.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        canvas.bounds = CGRect(origin: .zero, size: canvasSize)
        canvas.drawableSize = canvasSize
        canvas.minificationFilter = .trilinear
        canvas.magnificationFilter = .linear
        canvasLayer = canvas

        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.masksToBounds = true
        layer?.addSublayer(canvas)
        layoutCanvas()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("PlayerSurfaceView is created in code")
    }

    override public var isOpaque: Bool {
        true
    }

    /// Clicks and drags on the video go to the window (so it can be moved), not to this view.
    override public var mouseDownCanMoveWindow: Bool {
        true
    }

    override public func layout() {
        super.layout()
        layoutCanvas()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutCanvas()
    }

    /// Tells Core Animation whether the canvas carries brightness beyond standard white.
    /// The renderer sets this itself from its own thread when it switches the canvas to an
    /// HDR colour space; saying so here, on the main thread, makes sure it takes effect.
    func setExtendedDynamicRange(_ isExtended: Bool) {
        guard canvasLayer.wantsExtendedDynamicRangeContent != isExtended else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasLayer.wantsExtendedDynamicRangeContent = isExtended
        CATransaction.commit()
    }

    /// Centres the canvas in the view and scales it so the video fills as much of the view as it can.
    private func layoutCanvas() {
        let scale = CanvasGeometry.scale(canvas: canvasSize, video: videoSize, view: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        canvasLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }
}

/// Places a player's surface in a SwiftUI hierarchy.
struct PlayerSurface: NSViewRepresentable {
    let surface: PlayerSurfaceView

    func makeNSView(context _: Context) -> PlayerSurfaceView {
        surface
    }

    func updateNSView(_: PlayerSurfaceView, context _: Context) {}
}
