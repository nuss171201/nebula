import AppKit
@testable import AppUI
import MediaCore
import Testing

@Suite("Poster grid and strip layout")
struct PosterLayoutTests {
    @Test("A grid has as many columns of at least 140 points as fit, none wider than 190", arguments: [
        (188.0, 1, 140.0), (1000.0, 6, 143.0), (780.0, 4, 169.0), (400.0, 2, 167.0), (60.0, 1, 140.0),
    ])
    func columns(width: Double, count: Int, itemWidth: Double) {
        let columns = PosterGridMetrics.columns(forWidth: width)
        #expect(columns.count == count)
        #expect(Double(columns.itemWidth) == itemWidth)
        // They fit, with the spacing and the insets.
        if width >= 188 {
            #expect(CGFloat(count) * columns.itemWidth + CGFloat(count - 1) * PosterGridMetrics.spacing <= width - 2 * PosterGridMetrics.inset)
        }
    }

    @Test("Cells are as tall as the artwork's shape needs, plus the text")
    func itemSize() {
        #expect(PosterGridMetrics.itemSize(forWidth: 1000, shape: .poster) == CGSize(width: 143, height: 261))
        #expect(PosterGridMetrics.itemSize(forWidth: 1000, shape: .square) == CGSize(width: 143, height: 189))
        #expect(PosterGridMetrics.itemSize(forWidth: 1000, shape: .landscape) == CGSize(width: 143, height: 126))
    }

    @Test("A longer list that starts with the old one is an append; anything else is a new list")
    func changes() {
        typealias Metrics = PosterGridMetrics
        #expect(Metrics.change(from: ["a", "b"], to: ["a", "b"]) == .none)
        #expect(Metrics.change(from: [], to: []) == .none)
        #expect(Metrics.change(from: ["a", "b"], to: ["a", "b", "c", "d"]) == .appended(2 ..< 4))
        #expect(Metrics.change(from: [], to: ["a"]) == .replaced)
        #expect(Metrics.change(from: ["a", "b"], to: ["a"]) == .replaced)
        #expect(Metrics.change(from: ["a", "b"], to: ["b", "a", "c"]) == .replaced)
        #expect(Metrics.change(from: ["a", "b"], to: ["a", "c"]) == .replaced)
    }

    @Test("A strip's cards follow one another, each as wide as its shape, with the strip's insets at both ends")
    func row() {
        let layout = PosterRowLayout(shapes: [.poster, .landscape, .square], artworkHeight: 210)
        #expect(layout.frames.map(\.x) == [24, 178, 565])
        #expect(layout.frames.map(\.width) == [140, 373, 210])
        #expect(layout.contentWidth == 799)
        #expect(PosterRowLayout(shapes: [], artworkHeight: 210).contentWidth == 0)

        #expect(layout.indices(from: 0, to: 100) == 0 ..< 1)
        #expect(layout.indices(from: 170, to: 600) == 1 ..< 3)
        #expect(layout.indices(from: 164, to: 178) == 1 ..< 1)
        #expect(layout.indices(from: 900, to: 1200).isEmpty)
        #expect(layout.indices(from: -500, to: 5000) == 0 ..< 3)

        #expect(layout.index(at: 30) == 0)
        #expect(layout.index(at: 170) == nil)
        #expect(layout.index(at: 178) == 1)
        #expect(layout.index(at: 5000) == nil)
    }

    @Test("The action that opens a title is the same for a view as long as it belongs to the same owner")
    func openAction() {
        final class Owner {}
        let (first, second) = (Owner(), Owner())
        #expect(OpenTitleAction(owner: first) { _ in } == OpenTitleAction(owner: first) { _ in })
        #expect(OpenTitleAction(owner: first) { _ in } != OpenTitleAction(owner: second) { _ in })
        #expect(OpenTitleAction() == OpenTitleAction())
    }
}

@MainActor
@Suite("Poster grid and strip views")
struct PosterViewsTests {
    private func items(_ range: Range<Int>) -> [MetaItem] {
        range.map { MetaItem(id: "tt\($0)", type: .movie, name: "Title \($0)", releaseInfo: "20\($0)") }
    }

    /// A window that is never shown: enough for views to lay out and report what is visible.
    private func window(with view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    @Test("A strip holds cards only for what is in sight, moves them on as it scrolls, and opens the one pressed")
    func strip() throws {
        let all = items(0 ..< 60)
        let layout = PosterRowLayout(shapes: all.map(\.posterShape), artworkHeight: 210)
        let row = PosterRowView(frame: NSRect(x: 0, y: 0, width: layout.contentWidth, height: 256))
        var opened: [String] = []
        row.open = OpenTitleAction(owner: row) { opened.append($0.id) }
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 256))
        scrollView.documentView = row
        let window = window(with: scrollView, size: NSSize(width: 800, height: 256))
        row.show(all, layout: layout)
        window.layoutIfNeeded()

        func shown() -> [String] {
            row.subviews.compactMap { $0 as? PosterCellView }.filter { !$0.isHidden }
                .sorted { $0.frame.minX < $1.frame.minX }.compactMap { $0.accessibilityLabel() }
        }
        // 800 points of strip and 300 beyond: seven cards of 140 + 14, not sixty.
        #expect(shown() == (0 ..< 7).map { "Title \($0), 20\($0)" })

        scrollView.contentView.scroll(to: NSPoint(x: 3000, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let later = shown()
        #expect(later.first == "Title 17, 2017")
        #expect(later.count == 10)
        // The cards that went out of sight were handed on, not added to.
        #expect(row.subviews.count <= 12)

        let cell = try #require(row.subviews.compactMap { $0 as? PosterCellView }.first { $0.accessibilityLabel() == "Title 20, 2020" })
        #expect(cell.accessibilityPerformPress())
        #expect(opened == ["tt20"])
        #expect(cell.acceptsFirstResponder)

        // A new list replaces what is shown.
        row.show(items(100 ..< 103), layout: PosterRowLayout(shapes: [.poster, .poster, .poster], artworkHeight: 210))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(shown() == ["Title 100, 20100", "Title 101, 20101", "Title 102, 20102"])
    }

    @Test("A grid adds a page without starting over, starts over for a new list, and opens what is activated")
    func grid() {
        let coordinator = PosterGrid.Coordinator()
        let layout = NSCollectionViewFlowLayout()
        let collectionView = PosterCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.register(PosterCell.self, forItemWithIdentifier: PosterCell.identifier)
        collectionView.register(
            PosterGridFooterView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
            withIdentifier: PosterGridFooterView.identifier
        )
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        scrollView.documentView = collectionView
        coordinator.attach(to: collectionView, in: scrollView)
        let window = window(with: scrollView, size: NSSize(width: 1000, height: 700))
        var opened: [String] = []
        var appeared = Set<String>()
        coordinator.open = { opened.append($0.id) }
        coordinator.itemDidAppear = { appeared.insert($0.id) }

        coordinator.update(items: items(0 ..< 100), footer: .none)
        window.layoutIfNeeded()
        #expect(collectionView.numberOfItems(inSection: 0) == 100)
        #expect(layout.itemSize == PosterGridMetrics.itemSize(forWidth: collectionView.bounds.width, shape: .poster))
        // Only what is on screen was asked for, which is what lets the next page wait until it is needed.
        #expect(appeared.contains("tt0"))
        #expect(!appeared.contains("tt99"))
        let label = collectionView.item(at: IndexPath(item: 3, section: 0))?.view.accessibilityLabel()
        #expect(label == "Title 3, 203")

        // The next page: scrolled to where it was, with more below.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        coordinator.update(items: items(0 ..< 200), footer: .loading)
        window.layoutIfNeeded()
        #expect(collectionView.numberOfItems(inSection: 0) == 200)
        #expect(scrollView.contentView.bounds.origin.y == 600)

        collectionView.onActivate?(IndexPath(item: 150, section: 0))
        collectionView.onActivate?(IndexPath(item: 5000, section: 0))
        #expect(opened == ["tt150"])

        // Another catalog: from the top.
        coordinator.update(items: items(500 ..< 520), footer: .none)
        window.layoutIfNeeded()
        #expect(collectionView.numberOfItems(inSection: 0) == 20)
        #expect(scrollView.contentView.bounds.origin.y == 0)
        coordinator.detach()
    }
}
