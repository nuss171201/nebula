import AppKit
import QuartzCore
import SwiftUI

/// The view video is drawn into: a `CAMetalLayer` that the playback engine renders to
/// directly (through Vulkan on Metal). The engine owns presentation; this view only
/// keeps the layer's size and scale in step with the window.
public final class PlayerSurfaceView: NSView {
    let metalLayer: CAMetalLayer

    public init() {
        let layer = CAMetalLayer()
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.isOpaque = true
        layer.framebufferOnly = true
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        metalLayer = layer
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        wantsLayer = true
        self.layer = layer
        layerContentsRedrawPolicy = .never
        layer.frame = bounds
        updateDrawableSize()
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

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    /// The engine sizes its swapchain from the layer, so keep the pixel size current.
    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
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
