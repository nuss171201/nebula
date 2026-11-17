import AppKit
import MediaCore
import SwiftUI

/// How a grid of posters is laid out. Pure, so it can be tested.
enum PosterGridMetrics {
    static let minimumWidth: CGFloat = 140
    static let maximumWidth: CGFloat = 190
    static let spacing: CGFloat = 18
    static let lineSpacing: CGFloat = 22
    static let inset: CGFloat = 24
    /// The gap under the artwork and the two lines of text.
    static let textHeight: CGFloat = 46
    static let footerHeight: CGFloat = 64

    /// As many columns of at least the minimum width as fit, each as wide as it can be up to the maximum.
    static func columns(forWidth width: CGFloat) -> (count: Int, itemWidth: CGFloat) {
        let available = max(width - inset * 2, minimumWidth)
        let count = max(Int((available + spacing) / (minimumWidth + spacing)), 1)
        let itemWidth = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (count, min(itemWidth, maximumWidth).rounded(.down))
    }

    /// The size of every cell: artwork of the grid's shape above the text.
    static func itemSize(forWidth width: CGFloat, shape: PosterShape) -> CGSize {
        let itemWidth = columns(forWidth: width).itemWidth
        return CGSize(width: itemWidth, height: (itemWidth / shape.aspectRatio).rounded() + textHeight)
    }

    /// What became of a list between two updates, which decides how little the grid has to redo.
    enum Change: Equatable {
        case none
        /// The old items are all still there, in order, with more after them (the next page).
        case appended(Range<Int>)
        case replaced
    }

    static func change(from old: [String], to new: [String]) -> Change {
        if old == new {
            return .none
        }
        guard !old.isEmpty, new.count > old.count, new.prefix(old.count).elementsEqual(old) else { return .replaced }
        return .appended(old.count ..< new.count)
    }
}

/// A scrolling grid of poster cards that stays smooth however long it gets.
///
/// SwiftUI's lazy grid builds every card anew as it scrolls into view, which on a fast scroll
/// kept the main thread busy for 10 to 20 ms a row (measured with `Scripts/measure-scroll.sh`),
/// whatever the card contained. A collection view makes a screenful of cells once and hands
/// them new contents as they come round again.
struct PosterGrid: NSViewRepresentable {
    enum Footer: Equatable {
        case none
        case loading
        case failed(String)
    }

    var items: [MetaItem]
    var footer: Footer = .none
    /// Called as an item scrolls into view, for loading the next page in time.
    var itemDidAppear: (MetaItem) -> Void = { _ in }
    var open: (MetaItem) -> Void
    var retry: () -> Void = {}

    @Environment(\.imagePipeline) private var pipeline
    @Environment(\.displayScale) private var displayScale

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = PosterGridMetrics.spacing
        layout.minimumLineSpacing = PosterGridMetrics.lineSpacing
        let inset = PosterGridMetrics.inset
        layout.sectionInset = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)

        let collectionView = PosterCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsEmptySelection = true
        collectionView.register(PosterCell.self, forItemWithIdentifier: PosterCell.identifier)
        collectionView.register(
            PosterGridFooterView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter,
            withIdentifier: PosterGridFooterView.identifier
        )
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.setAccessibilityLabel("Titles")

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsFrameChangedNotifications = true
        context.coordinator.attach(to: collectionView, in: scrollView)
        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.pipeline = pipeline
        coordinator.maxPixelSize = Int((280 * displayScale).rounded(.up))
        coordinator.itemDidAppear = itemDidAppear
        coordinator.open = open
        coordinator.retry = retry
        coordinator.update(items: items, footer: footer)
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var pipeline: ImagePipeline?
        var maxPixelSize = 560
        var itemDidAppear: (MetaItem) -> Void = { _ in }
        var open: (MetaItem) -> Void = { _ in }
        var retry: () -> Void = {}

        private var items: [MetaItem] = []
        private var ids: [String] = []
        private var footer = Footer.none
        private weak var collectionView: PosterCollectionView?
        private weak var footerView: PosterGridFooterView?
        private var resizeObserver: (any NSObjectProtocol)?
        private var laidOutWidth: CGFloat = 0

        func attach(to collectionView: PosterCollectionView, in scrollView: NSScrollView) {
            self.collectionView = collectionView
            collectionView.onActivate = { [weak self] indexPath in
                self?.activate(indexPath)
            }
            // The cells' size follows the width, so a new width needs a new layout.
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.widthMayHaveChanged()
                }
            }
        }

        func detach() {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            resizeObserver = nil
        }

        func update(items newItems: [MetaItem], footer newFooter: Footer) {
            let newIDs = newItems.map(\.id)
            let change = PosterGridMetrics.change(from: ids, to: newIDs)
            items = newItems
            ids = newIDs
            updateItemSize()
            switch change {
            case .none:
                break
            case let .appended(range):
                collectionView?.insertItems(at: Set(range.map { IndexPath(item: $0, section: 0) }))
            case .replaced:
                collectionView?.reloadData()
                collectionView?.enclosingScrollView?.contentView.scroll(to: .zero)
            }
            if newFooter != footer {
                footer = newFooter
                footerView?.show(newFooter, retry: retry)
                collectionView?.collectionViewLayout?.invalidateLayout()
            }
        }

        private func widthMayHaveChanged() {
            guard let collectionView, collectionView.bounds.width != laidOutWidth else { return }
            laidOutWidth = collectionView.bounds.width
            updateItemSize()
        }

        /// One size for every cell, set on the layout itself: asked item by item, a long grid
        /// would cost a call per title every time a page is added.
        private func updateItemSize() {
            guard let collectionView, let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            let size = PosterGridMetrics.itemSize(forWidth: collectionView.bounds.width, shape: shape)
            if layout.itemSize != size {
                layout.itemSize = size
            }
        }

        private func activate(_ indexPath: IndexPath) {
            guard items.indices.contains(indexPath.item) else { return }
            collectionView?.deselectAll(nil)
            open(items[indexPath.item])
        }

        /// The shape the grid is laid out for: catalogs are of one shape, so the first item speaks for all.
        private var shape: PosterShape {
            items.first?.posterShape ?? .poster
        }

        // MARK: Data source and layout

        func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
            items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: PosterCell.identifier, for: indexPath)
            if let cell = cell as? PosterCell, items.indices.contains(indexPath.item) {
                cell.cellView.configure(with: items[indexPath.item], pipeline: pipeline, maxPixelSize: maxPixelSize)
                // For VoiceOver's "press"; clicks and keys go through the collection view.
                cell.cellView.onActivate = { [weak self] in
                    self?.activate(indexPath)
                }
            }
            return cell
        }

        func collectionView(_: NSCollectionView, willDisplay _: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            if items.indices.contains(indexPath.item) {
                itemDidAppear(items[indexPath.item])
            }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout _: NSCollectionViewLayout,
            referenceSizeForFooterInSection _: Int
        ) -> NSSize {
            footer == .none ? .zero : NSSize(width: collectionView.bounds.width, height: PosterGridMetrics.footerHeight)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: PosterGridFooterView.identifier, for: indexPath)
            if let view = view as? PosterGridFooterView {
                view.show(footer, retry: retry)
                footerView = view
            }
            return view
        }
    }
}

/// The collection view, with what a grid of links needs: a click opens, arrow keys move a
/// selection without opening, and Return or Space opens what is selected.
final class PosterCollectionView: NSCollectionView {
    var onActivate: ((IndexPath) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // The click selected the item under it; a click on empty space selected nothing.
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            onActivate?(indexPath)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Return, Enter, Space.
        if [36, 76, 49].contains(event.keyCode), let indexPath = selectionIndexPaths.first {
            onActivate?(indexPath)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// What is under the last row: the next page loading, or why it did not.
final class PosterGridFooterView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("poster-grid-footer")
    private var host: NSHostingView<AnyView>?

    func show(_ footer: PosterGrid.Footer, retry: @escaping () -> Void) {
        let content = switch footer {
        case .none: AnyView(EmptyView())
        case .loading: AnyView(ProgressView())
        case let .failed(message): AnyView(RetryMessage(message: message, retry: retry))
        }
        if let host {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            self.host = host
        }
    }
}
