import AppKit
import MediaCore

/// One reusable card of a `PosterGrid`.
final class PosterCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("poster")
    let cellView = PosterCellView()

    override func loadView() {
        view = cellView
    }

    override var isSelected: Bool {
        didSet { cellView.isSelected = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cellView.cancelLoad()
    }
}

/// Artwork with a title and a line of release text under it.
///
/// Everything is a plain layer. Nothing is created or laid out again while the grid scrolls,
/// only given new contents; and making a cell in the first place is cheap, which matters for
/// the first rows a scroll brings in, before there are cells to reuse (text fields and an
/// image view per cell made those rows cost 12 to 15 ms each).
final class PosterCellView: NSView {
    private let artwork = CALayer()
    private let title = CATextLayer()
    private let subtitle = CATextLayer()
    /// Shown only when a title has no artwork at all; made when first needed.
    private var placeholder: NSImageView?
    private var loadTask: Task<Void, Never>?
    private var shownURL: URL?
    private var isHovered = false {
        didSet { updateBorder() }
    }

    var isSelected = false {
        didSet { updateBorder() }
    }

    /// Opens the title. Set where the cell stands by itself (a strip); in a grid the
    /// collection view handles clicks and keys, and this serves VoiceOver's "press".
    var onActivate: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        artwork.cornerRadius = 8
        artwork.masksToBounds = true
        artwork.contentsGravity = .resizeAspectFill
        layer?.addSublayer(artwork)
        for (text, style) in [(title, NSFont.TextStyle.callout), (subtitle, .caption1)] {
            let font = NSFont.preferredFont(forTextStyle: style)
            text.font = font
            text.fontSize = font.pointSize
            text.truncationMode = .end
            text.actions = ["contents": NSNull(), "string": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(text)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateColors()
        updateBorder()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("PosterCellView is created in code")
    }

    override var isFlipped: Bool {
        true
    }

    func configure(with item: MetaItem, pipeline: ImagePipeline?, maxPixelSize: Int) {
        title.string = item.name
        subtitle.string = item.releaseInfo ?? ""
        toolTip = item.name
        setAccessibilityLabel([item.name, item.releaseInfo].compactMap(\.self).joined(separator: ", "))
        load(item.poster, from: pipeline, maxPixelSize: maxPixelSize)
    }

    /// The cell is about to show something else: what was being fetched for it is no longer wanted.
    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        isHovered = false
    }

    private func load(_ url: URL?, from pipeline: ImagePipeline?, maxPixelSize: Int) {
        loadTask?.cancel()
        loadTask = nil
        guard url != shownURL || artwork.contents == nil else { return }
        show(nil, for: url)
        guard let url, let pipeline else { return }
        if let cached = pipeline.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            show(cached, for: url)
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await pipeline.image(for: url, maxPixelSize: maxPixelSize), !Task.isCancelled else { return }
            self?.show(image, for: url)
        }
    }

    private func show(_ image: CGImage?, for url: URL?) {
        shownURL = url
        // No fade: dozens of posters arrive together, and each animation is a display update.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.contents = image
        CATransaction.commit()
        showPlaceholder(image == nil && url == nil)
    }

    private func showPlaceholder(_ isShown: Bool) {
        if isShown, placeholder == nil {
            let view = NSImageView()
            view.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            view.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title2)
            view.contentTintColor = .tertiaryLabelColor
            addSubview(view)
            placeholder = view
            needsLayout = true
        }
        placeholder?.isHidden = !isShown
    }

    override func layout() {
        super.layout()
        let artworkHeight = max(bounds.height - PosterGridMetrics.textHeight, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artwork.frame = CGRect(x: 0, y: 0, width: bounds.width, height: artworkHeight)
        title.frame = CGRect(x: 2, y: artworkHeight + 6, width: bounds.width - 2, height: 18)
        subtitle.frame = CGRect(x: 2, y: artworkHeight + 25, width: bounds.width - 2, height: 15)
        CATransaction.commit()
        placeholder?.frame = CGRect(x: (bounds.width - 32) / 2, y: (artworkHeight - 32) / 2, width: 32, height: 32)
    }

    /// Text layers draw at one pixel per point unless told the screen's scale.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        title.contentsScale = scale
        subtitle.contentsScale = scale
    }

    // MARK: Appearance and hover

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        updateBorder()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            artwork.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            title.foregroundColor = NSColor.labelColor.cgColor
            subtitle.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    private func updateBorder() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isSelected {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                artwork.borderColor = NSColor.controlAccentColor.cgColor
            }
            artwork.borderWidth = 3
        } else {
            artwork.borderColor = CGColor(gray: 1, alpha: isHovered ? 0.6 : 0.08)
            artwork.borderWidth = isHovered ? 2 : 1
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Activation (clicks, keys, VoiceOver)

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // In a grid the collection view wants the click; in a strip it is this card's.
        if onActivate == nil || enclosingCollectionView != nil {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let onActivate, enclosingCollectionView == nil, bounds.contains(convert(event.locationInWindow, from: nil)) {
            onActivate()
        } else {
            super.mouseUp(with: event)
        }
    }

    override var acceptsFirstResponder: Bool {
        onActivate != nil && enclosingCollectionView == nil
    }

    override var canBecomeKeyView: Bool {
        acceptsFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        // Return, Enter, Space.
        if let onActivate, [36, 76, 49].contains(event.keyCode) {
            onActivate()
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect {
        artwork.frame
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: artwork.frame, xRadius: 8, yRadius: 8).fill()
    }

    private var enclosingCollectionView: NSCollectionView? {
        var view = superview
        while let current = view {
            if let collectionView = current as? NSCollectionView {
                return collectionView
            }
            view = current.superview
        }
        return nil
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
    }
}
