import AppKit
import MediaCore
import SwiftUI

/// Opens a title's page.
///
/// Compared by who it belongs to, not by its closure: a bare closure in the environment
/// cannot be compared, so every view reading it would be evaluated again on every update.
struct OpenTitleAction: Equatable {
    private let owner: ObjectIdentifier?
    private let handler: @MainActor (MetaItem) -> Void

    /// Does nothing. For previews and views outside the main window.
    init() {
        owner = nil
        handler = { _ in }
    }

    init(owner: AnyObject, handler: @escaping @MainActor (MetaItem) -> Void) {
        self.owner = ObjectIdentifier(owner)
        self.handler = handler
    }

    @MainActor
    func callAsFunction(_ item: MetaItem) {
        handler(item)
    }

    static func == (lhs: OpenTitleAction, rhs: OpenTitleAction) -> Bool {
        lhs.owner == rhs.owner
    }
}

extension EnvironmentValues {
    /// Set by the main window.
    @Entry var openTitle = OpenTitleAction()
}

/// Where the cards of a horizontal strip go. Pure, so it can be tested.
struct PosterRowLayout: Equatable {
    static let spacing: CGFloat = 14
    static let inset: CGFloat = 24

    /// Each card's left edge and width, in order.
    private(set) var frames: [(x: CGFloat, width: CGFloat)] = []
    private(set) var contentWidth: CGFloat = 0

    init(shapes: [PosterShape], artworkHeight: CGFloat) {
        var x = Self.inset
        for shape in shapes {
            let width = (artworkHeight * shape.aspectRatio).rounded()
            frames.append((x, width))
            x += width + Self.spacing
        }
        contentWidth = shapes.isEmpty ? 0 : x - Self.spacing + Self.inset
    }

    static func == (lhs: PosterRowLayout, rhs: PosterRowLayout) -> Bool {
        lhs.contentWidth == rhs.contentWidth && lhs.frames.count == rhs.frames.count
            && zip(lhs.frames, rhs.frames).allSatisfy { $0.x == $1.x && $0.width == $1.width }
    }

    /// The cards that are at least partly between two x positions.
    func indices(from minX: CGFloat, to maxX: CGFloat) -> Range<Int> {
        guard let first = frames.firstIndex(where: { $0.x + $0.width > minX }) else { return 0 ..< 0 }
        let end = frames[first...].firstIndex { $0.x >= maxX } ?? frames.count
        return first ..< max(end, first)
    }

    /// The card under an x position, if any.
    func index(at x: CGFloat) -> Int? {
        frames.firstIndex { x >= $0.x && x < $0.x + $0.width }
    }
}

/// A horizontally scrolling strip of poster cards.
///
/// SwiftUI does the scrolling; the cards are the grid's layer-based cells, made only for the
/// part of the strip that is in view and reused as it scrolls. A strip of SwiftUI cards took
/// 17 to 31 ms to appear, which was a visible hitch each time Home scrolled a new row in.
struct PosterStrip: View {
    let items: [MetaItem]
    @Environment(\.openTitle) private var open

    var body: some View {
        let layout = PosterRowLayout(shapes: items.map(\.posterShape), artworkHeight: PosterCard.rowArtworkHeight)
        ScrollView(.horizontal) {
            PosterRow(items: items, layout: layout, open: open)
                .frame(width: layout.contentWidth, height: PosterCard.rowHeight)
        }
        .scrollIndicators(.hidden)
        .frame(height: PosterCard.rowHeight)
    }
}

private struct PosterRow: NSViewRepresentable {
    let items: [MetaItem]
    let layout: PosterRowLayout
    let open: OpenTitleAction

    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context _: Context) -> PosterRowView {
        PosterRowView()
    }

    func updateNSView(_ view: PosterRowView, context _: Context) {
        view.pipeline = pipeline
        view.maxPixelSize = Int((PosterCard.rowArtworkHeight * 16 / 9 * displayScale).rounded(.up))
        view.open = open
        view.show(items, layout: layout)
    }
}

/// The strip's content: as wide as all its cards, holding views only for the ones in sight.
final class PosterRowView: NSView {
    var pipeline: ImagePipeline?
    var maxPixelSize = 560
    var open = OpenTitleAction()

    private var items: [MetaItem] = []
    private var rowLayout = PosterRowLayout(shapes: [], artworkHeight: 0)
    private var cells: [Int: PosterCellView] = [:]
    private var spare: [PosterCellView] = []
    private var scrollObserver: (any NSObjectProtocol)?
    /// Cards are also kept this far outside the visible part, so that a scroll finds them ready.
    private static let margin: CGFloat = 300

    override var isFlipped: Bool {
        true
    }

    func show(_ newItems: [MetaItem], layout newLayout: PosterRowLayout) {
        guard newItems != items || newLayout != rowLayout else { return }
        items = newItems
        rowLayout = newLayout
        for (_, cell) in cells {
            recycle(cell)
        }
        cells = [:]
        updateVisibleCells()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeScrolling()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScrolling()
        updateVisibleCells()
    }

    override func layout() {
        super.layout()
        updateVisibleCells()
    }

    /// The strip scrolls inside SwiftUI's scroll view; its clip view says when.
    private func observeScrolling() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        scrollObserver = nil
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateVisibleCells()
            }
        }
    }

    private func updateVisibleCells() {
        guard window != nil else { return }
        // Without a scroll view to ask (should SwiftUI ever stop using one), everything counts as visible.
        let visible = enclosingScrollView == nil ? bounds : visibleRect
        let wanted = rowLayout.indices(from: visible.minX - Self.margin, to: visible.maxX + Self.margin)
        for (index, cell) in cells where !wanted.contains(index) {
            recycle(cell)
            cells[index] = nil
        }
        for index in wanted where cells[index] == nil && items.indices.contains(index) {
            let cell = spare.popLast() ?? PosterCellView()
            let frame = rowLayout.frames[index]
            cell.frame = CGRect(x: frame.x, y: 0, width: frame.width, height: bounds.height)
            let item = items[index]
            cell.configure(with: item, pipeline: pipeline, maxPixelSize: maxPixelSize)
            cell.onActivate = { [weak self] in
                self?.open(item)
            }
            cell.isHidden = false
            if cell.superview !== self {
                addSubview(cell)
            }
            cells[index] = cell
        }
    }

    private func recycle(_ cell: PosterCellView) {
        cell.cancelLoad()
        cell.onActivate = nil
        cell.isHidden = true
        spare.append(cell)
    }
}
