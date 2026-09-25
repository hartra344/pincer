#if os(iOS)
import PincerKit
import SwiftUI
import UIKit

/// Chat transcript backed by `UICollectionView`. Rows are drawn natively from layouts computed by
/// `TranscriptRenderer`, and placed by a layout that knows every row's height up front, so nothing
/// self-sizes on screen. Only rows near the viewport are laid out eagerly, the rest while the
/// reader isn't scrolling, and the row the reader is looking at stays put while history loads
/// above it or a reply streams in below.
struct TranscriptList: UIViewRepresentable {
    let rows: [TranscriptRow]
    let context: TranscriptContext
    /// Extra space below the last row for content floating over the transcript (the composer).
    var bottomInset: CGFloat = 0
    /// Extra space above the first row, for a toolbar the transcript scrolls under.
    var topInset: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator(context: self.context) }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(rows: self.rows, context: self.context, insets: (self.topInset, self.bottomInset))
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private enum Anchor: Equatable {
            case bottom
            /// Row id, and how far its top sits below the top of the viewport.
            case row(String, CGFloat)
        }

        private struct Height {
            var value: CGFloat
            var width: CGFloat
            var measured: Bool
        }

        private var context: TranscriptContext
        private var rows: [TranscriptRow] = []
        private var index: [String: Int] = [:]
        private var heights: [String: Height] = [:]
        /// Top of each row in content coordinates, and the total content height.
        fileprivate private(set) var tops: [CGFloat] = []
        fileprivate private(set) var contentHeight: CGFloat = 0
        private var anchor = Anchor.bottom
        private var isAdjusting = false
        private var isScrollingToTop = false
        private var lastOffset: CGFloat = 0
        private var prefetchScheduled = false
        private let renderer: TranscriptRenderer
        private weak var collectionView: TranscriptCollectionView?

        init(context: TranscriptContext) {
            self.context = context
            self.renderer = TranscriptRenderer(context: context)
            super.init()
            self.renderer.onInvalidate = { [weak self] ids, keepInPlace in
                self?.invalidate(ids, keepInPlace: keepInPlace)
            }
        }

        func makeCollectionView() -> UICollectionView {
            let layout = TranscriptCollectionLayout()
            layout.coordinator = self
            let view = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
            view.coordinator = self
            view.backgroundColor = .clear
            view.allowsSelection = false
            view.keyboardDismissMode = .interactive
            view.alwaysBounceVertical = true
            // UIKit adds the safe area (bars, home indicator; the keyboard is handled by SwiftUI
            // resizing the view); the owner's insets only cover chrome floating over the list.
            view.contentInsetAdjustmentBehavior = .always
            view.contentInset = UIEdgeInsets(top: TranscriptLayout.verticalInset, left: 0,
                                             bottom: TranscriptLayout.verticalInset, right: 0)
            view.register(TranscriptCell.self, forCellWithReuseIdentifier: TranscriptCell.reuseIdentifier)
            view.dataSource = self
            view.delegate = self
            self.collectionView = view
            return view
        }

        // MARK: Data

        func update(rows newRows: [TranscriptRow], context: TranscriptContext, insets: (top: CGFloat, bottom: CGFloat)) {
            let contextChanged = context.differs(from: self.context)
            self.context = context
            self.renderer.update(context: context)
            guard let view = self.collectionView else { return }
            let top = TranscriptLayout.verticalInset + max(0, insets.top)
            let bottom = TranscriptLayout.verticalInset + max(0, insets.bottom)
            if abs(view.contentInset.top - top) > 0.5 || abs(view.contentInset.bottom - bottom) > 0.5 {
                self.isAdjusting = true
                view.contentInset.top = top
                view.contentInset.bottom = bottom
                view.verticalScrollIndicatorInsets = UIEdgeInsets(top: max(0, insets.top), left: 0,
                                                                  bottom: max(0, insets.bottom), right: 0)
                self.isAdjusting = false
                if !self.rows.isEmpty, !contextChanged { self.settle() }
            }
            if contextChanged {
                self.heights.removeAll()
                self.rows = []
            }
            var seen = Set<String>()
            let unique = newRows.filter { seen.insert($0.id).inserted }
            guard unique != self.rows else { return }
            let oldRows = self.rows
            self.rows = unique
            self.index = Dictionary(unique.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

            if oldRows.isEmpty {
                self.anchor = .bottom
                self.rebuildOffsets()
                self.reload(view)
                self.settle()
                return
            }

            // Rows whose content changed (a streaming reply, a tool finishing) are updated in
            // place; their old height stays as the estimate until they're measured again.
            let oldById = Dictionary(oldRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for item in unique {
                guard let old = oldById[item.id], old != item else { continue }
                self.heights[item.id]?.measured = false
            }
            if oldRows.map(\.id) != unique.map(\.id) {
                // Sending jumps to the end, even from far up, and follows the reply from there.
                let oldIds = Set(oldRows.map(\.id))
                if unique.contains(where: { !oldIds.contains($0.id) && $0.isPendingSend }) { self.anchor = .bottom }
                // Rows only come and go when a message is sent or arrives, or history loads, so a
                // reload (which re-dequeues the few cells on screen) is cheap enough.
                self.rebuildOffsets()
                self.reload(view)
            }
            self.settle()
        }

        private func reload(_ view: UICollectionView) {
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            UIView.performWithoutAnimation {
                view.reloadData()
            }
        }

        /// Rows whose layout changed without the rows themselves changing: an image arrived, a
        /// card opened, a setting changed. `keepInPlace` is a row the reader just tapped, which
        /// should stay where it is on screen while it grows or shrinks below that point.
        private func invalidate(_ ids: Set<String>?, keepInPlace: String?) {
            if let ids {
                for id in ids { self.heights[id]?.measured = false }
            } else {
                for id in self.heights.keys { self.heights[id]?.measured = false }
            }
            if let keepInPlace, let row = self.index[keepInPlace], let view = self.collectionView {
                self.anchor = .row(keepInPlace, self.tops[row] - view.contentOffset.y)
                self.settle()
                self.anchor = self.currentAnchor()
            } else {
                self.settle()
            }
        }

        /// Measures rows around the viewport, applies any height changes, puts the reader back
        /// where they were and brings the cells on screen up to date.
        fileprivate func settle() {
            guard let view = self.collectionView else { return }
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            // Jump to the anchor first so the rows measured are the ones about to be on screen.
            self.restore(self.anchor)
            if self.measureAroundViewport() { self.applyHeights() }
            self.restore(self.anchor)
            view.layoutIfNeeded()
            self.refreshVisibleCells()
            self.schedulePrefetch()
        }

        private func refreshVisibleCells() {
            guard let view = self.collectionView else { return }
            let width = self.width
            guard width > 40 else { return }
            for path in view.indexPathsForVisibleItems where path.item < self.rows.count {
                guard let cell = view.cellForItem(at: path) as? TranscriptCell else { continue }
                cell.apply(self.renderer.layout(for: self.rows[path.item], width: width), actions: self.renderer)
            }
        }

        /// The viewport changed size: rotation, split view, the keyboard or the composer.
        fileprivate func viewportChanged() {
            self.settle()
        }

        // MARK: Heights

        /// Rows span the safe area, so they don't run under the notch or rounded corners in
        /// landscape.
        fileprivate var horizontalInsets: (left: CGFloat, right: CGFloat) {
            guard let view = self.collectionView else { return (0, 0) }
            return (view.safeAreaInsets.left, view.safeAreaInsets.right)
        }

        fileprivate var width: CGFloat {
            guard let view = self.collectionView else { return 0 }
            let insets = self.horizontalInsets
            return max(0, view.bounds.width - insets.left - insets.right)
        }

        private func height(at row: Int) -> CGFloat {
            let item = self.rows[row]
            if let height = self.heights[item.id] { return height.value }
            let estimate = TranscriptLayout.estimatedHeight(item, width: self.width)
            self.heights[item.id] = Height(value: estimate, width: self.width, measured: false)
            return estimate
        }

        private func rebuildOffsets() {
            var tops: [CGFloat] = []
            tops.reserveCapacity(self.rows.count)
            var y: CGFloat = 0
            for row in self.rows.indices {
                if row > 0 { y += TranscriptLayout.rowSpacing }
                tops.append(y)
                y += self.height(at: row)
            }
            self.tops = tops
            self.contentHeight = y
        }

        fileprivate func frame(at row: Int) -> CGRect {
            let insets = self.horizontalInsets
            let height = self.heights[self.rows[row].id]?.value ?? 1
            return CGRect(x: insets.left, y: self.tops[row], width: self.width, height: height)
        }

        /// The row whose frame contains `y`, or the nearest one.
        fileprivate func row(at y: CGFloat) -> Int? {
            guard !self.tops.isEmpty else { return nil }
            var low = 0, high = self.tops.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if self.tops[mid] <= y { low = mid } else { high = mid - 1 }
            }
            return low
        }

        private func applyHeights() {
            self.rebuildOffsets()
            self.collectionView?.collectionViewLayout.invalidateLayout()
        }

        private func measure(_ row: Int, width: CGFloat) -> Bool {
            let item = self.rows[row]
            if let height = self.heights[item.id], height.measured, height.width == width { return false }
            let old = self.heights[item.id]?.value
            let value = max(1, self.renderer.layout(for: item, width: width).height)
            self.heights[item.id] = Height(value: value, width: width, measured: true)
            return old.map { abs($0 - value) > 0.5 } ?? true
        }

        /// Measures unmeasured rows from a screen above the viewport to a screen below it, so rows
        /// have their real height before they scroll into view. Returns whether any changed.
        private func measureAroundViewport() -> Bool {
            guard let view = self.collectionView, !self.rows.isEmpty else { return false }
            let width = self.width
            guard width > 40 else { return false }
            let visible = CGRect(origin: view.contentOffset, size: view.bounds.size)
            let around = visible.insetBy(dx: 0, dy: -max(visible.height, 200))
            guard let first = self.row(at: around.minY), let last = self.row(at: around.maxY) else { return false }
            var changed = false
            for row in first...last where self.measure(row, width: width) { changed = true }
            return changed
        }

        /// Measures the rest of the transcript in small slices while the reader isn't scrolling,
        /// nearest rows first, so heights are final before rows scroll into view. Correcting a
        /// height mid-scroll means moving the scroll position under the reader's finger.
        private func schedulePrefetch() {
            guard !self.prefetchScheduled else { return }
            self.prefetchScheduled = true
            DispatchQueue.main.async { [weak self] in self?.prefetchStep() }
        }

        private func prefetchStep() {
            self.prefetchScheduled = false
            guard let view = self.collectionView, !self.rows.isEmpty,
                  !view.isTracking, !view.isDecelerating, !self.isScrollingToTop else { return }
            let width = self.width
            guard width > 40 else { return }
            let center = self.row(at: view.contentOffset.y + view.bounds.height / 2) ?? self.rows.count - 1
            let deadline = Date().addingTimeInterval(0.004)
            var changed = false
            var remaining = false
            // Walk outward from the viewport: below, above, below, above…
            var below = center, above = center - 1
            while below < self.rows.count || above >= 0 {
                for row in [below, above] where row >= 0 && row < self.rows.count {
                    let item = self.rows[row]
                    if let height = self.heights[item.id], height.measured, height.width == width { continue }
                    if Date() >= deadline { remaining = true; break }
                    if self.measure(row, width: width) { changed = true }
                }
                if remaining { break }
                below += 1
                above -= 1
            }
            if changed {
                self.isAdjusting = true
                self.applyHeights()
                self.restore(self.anchor)
                self.isAdjusting = false
            }
            if remaining { self.schedulePrefetch() }
        }

        // MARK: Cells

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            self.rows.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TranscriptCell.reuseIdentifier, for: indexPath)
            if let cell = cell as? TranscriptCell, indexPath.item < self.rows.count {
                cell.apply(self.renderer.layout(for: self.rows[indexPath.item], width: self.width), actions: self.renderer)
            }
            return cell
        }

        // MARK: Scrolling

        fileprivate var minOffset: CGFloat {
            -(self.collectionView?.adjustedContentInset.top ?? 0)
        }

        fileprivate var maxOffset: CGFloat {
            guard let view = self.collectionView else { return 0 }
            return max(self.minOffset, self.contentHeight + view.adjustedContentInset.bottom - view.bounds.height)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let offset = scrollView.contentOffset.y
            defer { self.lastOffset = offset }
            // Only the reader moves the anchor: layout changes and inset changes keep it.
            guard !self.isAdjusting,
                  scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || self.isScrollingToTop
            else { return }
            // Scrolling up leaves the bottom right away; only scrolling down re-sticks early.
            let movingUp = offset < self.lastOffset - 0.5
            self.anchor = self.currentAnchor(stickDistance: movingUp ? 1 : TranscriptLayout.stickToBottomDistance)
            guard self.measureAroundViewport() else { return }
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            self.applyHeights()
            self.restore(self.anchor)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { self.scrollEnded() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            self.scrollEnded()
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            self.isScrollingToTop = true
            return true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            self.isScrollingToTop = false
            self.scrollEnded()
        }

        private func scrollEnded() {
            self.anchor = self.currentAnchor()
            self.schedulePrefetch()
        }

        /// The row at the middle of the viewport, or the bottom when the reader is at the end. The
        /// middle row is used because rows entering at the edges may still change height.
        private func currentAnchor(stickDistance: CGFloat = TranscriptLayout.stickToBottomDistance) -> Anchor {
            guard let view = self.collectionView, !self.rows.isEmpty else { return .bottom }
            let offset = view.contentOffset.y
            if self.maxOffset - offset <= stickDistance { return .bottom }
            guard let row = self.row(at: offset + view.bounds.height / 2) else { return .bottom }
            return .row(self.rows[row].id, self.tops[row] - offset)
        }

        private func restore(_ anchor: Anchor) {
            guard let view = self.collectionView else { return }
            let target: CGFloat
            switch anchor {
            case .bottom:
                target = self.maxOffset
            case let .row(id, offset):
                guard let row = self.index[id], row < self.tops.count else {
                    self.anchor = self.currentAnchor()
                    return
                }
                target = min(max(self.tops[row] - offset, self.minOffset), self.maxOffset)
            }
            guard abs(view.contentOffset.y - target) > 0.5 else { return }
            let wasAdjusting = self.isAdjusting
            self.isAdjusting = true
            view.contentOffset.y = target
            self.isAdjusting = wasAdjusting
        }
    }
}

/// Tells the coordinator when the viewport changes size or insets, so it re-measures at the new
/// width and keeps the same message in view.
private final class TranscriptCollectionView: UICollectionView {
    weak var coordinator: TranscriptList.Coordinator?
    private var lastSize = CGSize.zero
    private var lastInsets = UIEdgeInsets.zero

    override func layoutSubviews() {
        let insets = self.adjustedContentInset
        if self.bounds.size != self.lastSize || insets != self.lastInsets {
            self.lastSize = self.bounds.size
            self.lastInsets = insets
            self.coordinator?.viewportChanged()
        }
        super.layoutSubviews()
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        // Scrolling that starts on a tappable part (a tool header, an image) still scrolls.
        view is UIControl ? true : super.touchesShouldCancel(in: view)
    }
}

/// Places rows at the heights the coordinator measured. Nothing is sized by the cells themselves.
private final class TranscriptCollectionLayout: UICollectionViewLayout {
    weak var coordinator: TranscriptList.Coordinator?

    override var collectionViewContentSize: CGSize {
        CGSize(width: self.collectionView?.bounds.width ?? 0, height: self.coordinator?.contentHeight ?? 0)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let coordinator, let first = coordinator.row(at: rect.minY) else { return [] }
        var attributes: [UICollectionViewLayoutAttributes] = []
        var row = first
        while row < coordinator.tops.count, coordinator.tops[row] <= rect.maxY {
            attributes.append(self.attributes(row, coordinator))
            row += 1
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let coordinator, indexPath.item < coordinator.tops.count else { return nil }
        return self.attributes(indexPath.item, coordinator)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != self.collectionView?.bounds.width
    }

    private func attributes(_ row: Int, _ coordinator: TranscriptList.Coordinator) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: row, section: 0))
        attributes.frame = coordinator.frame(at: row)
        return attributes
    }
}

private final class TranscriptCell: UICollectionViewCell {
    static let reuseIdentifier = "TranscriptCell"

    private let content = TranscriptRowView()
    private var serial: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.contentView.addSubview(self.content)
        self.backgroundConfiguration = .clear()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Layout attributes are final; skip the self-sizing pass.
    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        attributes
    }

    func apply(_ layout: TranscriptRowLayout, actions: TranscriptRowActions) {
        // Top-aligned at the layout's own size, so a row briefly taller than its slot (between a
        // change and the layout catching up) grows downward.
        let frame = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        if self.content.frame != frame { self.content.frame = frame }
        guard layout.serial != self.serial else { return }
        self.serial = layout.serial
        self.content.apply(layout, actions: actions)
    }
}
#endif
