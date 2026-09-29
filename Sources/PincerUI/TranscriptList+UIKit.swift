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
    /// Find in chat's matches to highlight, and the selected one to scroll to.
    var highlight = TranscriptHighlight()
    /// A message to scroll to and flash, e.g. from a `pincer://` link.
    var jump: TranscriptJump?

    func makeCoordinator() -> Coordinator { Coordinator(context: self.context) }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.update(rows: self.rows, context: self.context, insets: (self.topInset, self.bottomInset))
        context.coordinator.apply(self.highlight)
        context.coordinator.apply(self.jump)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        private enum Anchor: Equatable {
            case bottom
            /// The reader is at the very top, wherever the rows below end up.
            case top
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
        /// Ids whose height value changed since the offsets were last built.
        private var dirtyHeights = Set<String>()
        private var anchor = Anchor.bottom
        private var isAdjusting = false
        private var isScrollingToTop = false
        private var lastOffset: CGFloat = 0
        private var prefetchScheduled = false
        private var scrollMeasureScheduled = false
        private var queue = TranscriptMeasureQueue()
        private var queueWidth: CGFloat = 0
        private var fixesScheduled = false
        /// Time spent measuring rows in idle slices and scroll callbacks, for the probe.
        var prefetchStats: (steps: Int, rowsMeasured: Int, seconds: Double) = (0, 0, 0)
        let renderer: TranscriptRenderer
        private weak var collectionView: TranscriptCollectionView?

        init(context: TranscriptContext) {
            self.context = context
            self.renderer = TranscriptRenderer(context: context)
            super.init()
            self.renderer.onInvalidate = { [weak self] ids, keepInPlace in
                self?.invalidate(ids, keepInPlace: keepInPlace)
            }
            self.renderer.visibleRowIds = { [weak self] in self?.visibleRowIds() ?? [] }
            self.renderer.onRelayout = { [weak self] id, width, height in
                self?.relaidOut(id, width: width, height: height)
            }
            self.renderer.onReveal = { [weak self] id in
                guard let self else { return }
                // A row paged in from older history arrives with the next update.
                if self.index[id] != nil { self.reveal(id) } else { self.pendingReveal = id }
            }
        }

        private var pendingReveal: String?

        private func revealPending() {
            guard let id = self.pendingReveal, self.index[id] != nil else { return }
            self.pendingReveal = nil
            self.reveal(id)
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
            defer { self.revealPending() }
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
            if case .top = self.anchor, unique.first?.id != self.rows.first?.id {
                // Rows arriving above: keep reading the same row instead of following the top.
                self.anchor = self.currentAnchor(allowTop: false)
            }
            // Streaming: same ids, only the last row differs. One pass, no diffing.
            if let last = unique.last, self.rows.count == unique.count, self.rows.last?.id == last.id,
               self.rows.dropLast() == unique.dropLast() {
                guard self.rows[self.rows.count - 1] != last else { return }
                self.rows[self.rows.count - 1] = last
                self.heights[last.id]?.measured = false
                self.queue.markUnmeasured(unique.count - 1)
                self.settle()
                return
            }
            guard unique != self.rows else { return }
            let oldRows = self.rows
            self.rows = unique
            self.index = Dictionary(unique.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

            if oldRows.isEmpty {
                self.anchor = .bottom
                self.rebuildQueue()
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
            self.rebuildQueue()
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
                for id in ids {
                    self.heights[id]?.measured = false
                    if let row = self.index[id] { self.queue.markUnmeasured(row) }
                }
            } else {
                for id in self.heights.keys { self.heights[id]?.measured = false }
                self.queue.markAllUnmeasured(count: self.rows.count)
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
            // Measuring rows above the anchor moves the viewport over rows that weren't measured
            // yet, so go again until the rows on screen are all measured.
            var passes = 0
            while passes < 4, self.measureAroundViewport() {
                self.applyHeights()
                self.restore(self.anchor)
                passes += 1
            }
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
                let layout = self.renderer.layout(for: self.rows[path.item], width: width)
                self.correctHeight(self.rows[path.item].id, width: width, height: layout.height)
                guard let cell = view.cellForItem(at: path) as? TranscriptCell else { continue }
                cell.apply(layout, actions: self.renderer)
            }
            self.pinVisibleImages()
        }

        private func pinVisibleImages() {
            guard let view = self.collectionView, !self.rows.isEmpty, self.width > 40,
                  let first = self.row(at: view.contentOffset.y),
                  let last = self.row(at: view.contentOffset.y + view.bounds.height) else { return }
            self.renderer.pinImages(of: self.rows[first...last], width: self.width)
        }

        /// The viewport changed size: rotation, split view, the keyboard or the composer.
        fileprivate func viewportChanged() {
            self.settle()
        }

        /// Highlights Find's matches and scrolls the selected one into view when asked to.
        private var lastJump: UUID?

        func apply(_ jump: TranscriptJump?) {
            guard let jump, jump.id != self.lastJump else { return }
            self.lastJump = jump.id
            self.renderer.showOriginal(jump.messageId, missingNotice: PincerRoute.Notice.unknownMessage)
        }

        func apply(_ highlight: TranscriptHighlight) {
            guard let id = self.renderer.update(highlight: highlight) else { return }
            self.reveal(id)
        }

        /// Scrolls so the selected match (or the top of its row) sits a little above the middle
        /// of the visible area, clear of the bars and chrome floating over the transcript.
        private func reveal(_ id: String) {
            guard let view = self.collectionView, let row = self.index[id] else { return }
            let width = self.width
            guard width > 40 else { return }
            let layout = self.renderer.layout(for: self.rows[row], width: width)
            let old = self.heights[id]?.value
            self.heights[id] = Height(value: max(1, layout.height), width: width, measured: true)
            self.syncQueueWidth(width)
            self.queue.markMeasured(row)
            if old.map({ abs($0 - layout.height) > 0.5 }) ?? true {
                self.dirtyHeights.insert(id)
                self.applyHeights()
            }
            let insets = view.adjustedContentInset
            let visible = max(view.bounds.height - insets.top - insets.bottom, 1)
            let y = min(layout.matchY ?? 0, layout.height)
            self.anchor = .row(id, insets.top + visible * 0.4 - y)
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
            let estimate = TranscriptLayout.estimatedHeight(item, width: self.width, hasReactions: { self.context.hasReactions($0) })
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
            self.dirtyHeights.removeAll()
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
            // Only the last row moved (a streaming reply): nothing above it shifts, so adjust the
            // content height and invalidate that one item.
            if self.dirtyHeights.count == 1, let last = self.rows.last, self.dirtyHeights.contains(last.id),
               self.tops.count == self.rows.count, let top = self.tops.last {
                let new = self.height(at: self.rows.count - 1)
                let delta = new - (self.contentHeight - top)
                self.contentHeight += delta
                self.dirtyHeights.removeAll()
                if let layout = self.collectionView?.collectionViewLayout {
                    let context = UICollectionViewLayoutInvalidationContext()
                    context.invalidateItems(at: [IndexPath(item: self.rows.count - 1, section: 0)])
                    context.contentSizeAdjustment = CGSize(width: 0, height: delta)
                    layout.invalidateLayout(with: context)
                }
                return
            }
            self.rebuildOffsets()
            self.collectionView?.collectionViewLayout.invalidateLayout()
        }

        private func measure(_ row: Int, width: CGFloat) -> Bool {
            let item = self.rows[row]
            if let height = self.heights[item.id], height.measured, height.width == width {
                self.queue.markMeasured(row)
                return false
            }
            let old = self.heights[item.id]?.value
            let value = max(1, self.renderer.layout(for: item, width: width).height)
            self.heights[item.id] = Height(value: value, width: width, measured: true)
            self.queue.markMeasured(row)
            self.prefetchStats.rowsMeasured += 1
            let moved = old.map { abs($0 - value) > 0.5 } ?? true
            if moved { self.dirtyHeights.insert(item.id) }
            return moved
        }

        private func syncQueueWidth(_ width: CGFloat) {
            guard width != self.queueWidth else { return }
            self.queueWidth = width
            self.queue.markAllUnmeasured(count: self.rows.count)
        }

        /// Recomputes what needs measuring after rows came, went or changed.
        private func rebuildQueue() {
            let width = self.width
            self.queueWidth = width
            self.queue.rebuild(count: self.rows.count) { row in
                guard let height = self.heights[self.rows[row].id] else { return true }
                return !height.measured || height.width != width
            }
        }

        private func visibleRowIds() -> Set<String> {
            guard let view = self.collectionView, !self.rows.isEmpty,
                  let first = self.row(at: view.contentOffset.y),
                  let last = self.row(at: view.contentOffset.y + view.bounds.height) else { return [] }
            return Set(self.rows[first...last].map(\.id))
        }

        /// The rows within `screens` viewport heights of the viewport, and the one in the middle.
        private func window(screens: CGFloat, minimum: CGFloat = 200) -> (range: ClosedRange<Int>, center: Int)? {
            guard let view = self.collectionView, !self.rows.isEmpty else { return nil }
            let visible = CGRect(origin: view.contentOffset, size: view.bounds.size)
            let around = visible.insetBy(dx: 0, dy: -max(visible.height * screens, minimum))
            guard let first = self.row(at: around.minY), let last = self.row(at: around.maxY),
                  let center = self.row(at: visible.midY) else { return nil }
            return (first...last, center)
        }

        /// Measures unmeasured rows from a screen above the viewport to a screen below it, so rows
        /// have their real height before they scroll into view. Returns whether any changed.
        private func measureAroundViewport() -> Bool {
            let width = self.width
            guard width > 40, let window = self.window(screens: 1) else { return false }
            self.syncQueueWidth(width)
            let start = Date()
            defer { self.prefetchStats.seconds += Date().timeIntervalSince(start) }
            var changed = false
            for row in self.queue.next(center: window.center, window: window.range, limit: .max)
            where self.measure(row, width: width) { changed = true }
            return changed
        }

        /// The scroll callback's share: rows on screen and a little beyond, within a few
        /// milliseconds. Whatever doesn't fit waits for the next turn of the run loop.
        private func measureNearViewport() -> Bool {
            let width = self.width
            guard width > 40, let window = self.window(screens: 0.5) else { return false }
            self.syncQueueWidth(width)
            let start = Date()
            defer { self.prefetchStats.seconds += Date().timeIntervalSince(start) }
            let deadline = start.addingTimeInterval(0.004)
            var changed = false
            // Rows on screen are always measured; only the margin is held to the budget.
            if let onScreen = self.window(screens: 0, minimum: 0) {
                for row in self.queue.next(center: onScreen.center, window: onScreen.range, limit: .max)
                where self.measure(row, width: width) { changed = true }
            }
            for row in self.queue.next(center: window.center, window: window.range, limit: .max) {
                if Date() >= deadline {
                    self.scheduleScrollMeasure()
                    break
                }
                if self.measure(row, width: width) { changed = true }
            }
            return changed
        }

        private func scheduleScrollMeasure() {
            guard !self.scrollMeasureScheduled else { return }
            self.scrollMeasureScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollMeasureScheduled = false
                self.applyNearViewport()
            }
        }

        private func applyNearViewport() {
            guard self.measureNearViewport() else { return }
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            self.applyHeights()
            self.restore(self.anchor)
        }

        /// A row's layout was rebuilt after being evicted from the renderer's cache. If a change
        /// (a reaction, say) made it a different height than measured, correct the layout.
        private func relaidOut(_ id: String, width: CGFloat, height: CGFloat) {
            self.correctHeight(id, width: width, height: height)
        }

        /// If a row's fresh layout is a different height than the one stored, fixes the layout on
        /// the next turn (this can run while collection view is building cells).
        private func correctHeight(_ id: String, width: CGFloat, height: CGFloat) {
            guard width == self.width, self.index[id] != nil, let old = self.heights[id], old.measured,
                  old.width == width, abs(old.value - height) > 0.5 else { return }
            self.heights[id] = Height(value: max(1, height), width: width, measured: true)
            self.dirtyHeights.insert(id)
            guard !self.fixesScheduled else { return }
            self.fixesScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fixesScheduled = false
                guard !self.dirtyHeights.isEmpty else { return }
                self.isAdjusting = true
                defer { self.isAdjusting = false }
                self.applyHeights()
                self.restore(self.anchor)
            }
        }

        /// Measures the rest of the transcript near the viewport in small slices while the reader
        /// isn't scrolling, nearest rows first, so heights are final before rows scroll into view.
        /// Correcting a height mid-scroll means moving the scroll position under the reader's
        /// finger. Rows more than `screensAhead` screens away keep their estimates, and once the
        /// window is measured a step costs no more than finding the window.
        private func schedulePrefetch() {
            guard !self.prefetchScheduled else { return }
            self.prefetchScheduled = true
            DispatchQueue.main.async { [weak self] in self?.prefetchStep() }
        }

        func prefetchStep() {
            self.prefetchScheduled = false
            guard let view = self.collectionView, !self.queue.isEmpty,
                  !view.isTracking, !view.isDecelerating, !self.isScrollingToTop else { return }
            let width = self.width
            guard width > 40, let window = self.window(screens: CGFloat(TranscriptMeasureQueue.screensAhead)) else { return }
            self.syncQueueWidth(width)
            let start = Date()
            defer {
                self.prefetchStats.steps += 1
                self.prefetchStats.seconds += Date().timeIntervalSince(start)
            }
            let deadline = start.addingTimeInterval(0.004)
            var changed = false
            var remaining = false
            var measured = 0
            while !remaining {
                let batch = self.queue.next(center: window.center, window: window.range, limit: 8)
                if batch.isEmpty { break }
                let before = self.queue.count
                for row in batch {
                    if measured > 0, Date() >= deadline { remaining = true; break }
                    if self.measure(row, width: width) { changed = true }
                    measured += 1
                }
                if self.queue.count == before { break }
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
                let item = self.rows[indexPath.item]
                let layout = self.renderer.layout(for: item, width: self.width)
                self.correctHeight(item.id, width: self.width, height: layout.height)
                cell.apply(layout, actions: self.renderer)
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
            // The status-bar scroll to top is an animation that setting the offset would cut
            // short; it finishes at the top and is settled once it gets there.
            guard !self.isScrollingToTop else { return }
            // Scrolling up leaves the bottom right away; only scrolling down re-sticks early.
            let movingUp = offset < self.lastOffset - 0.5
            self.anchor = self.currentAnchor(stickDistance: movingUp ? 1 : TranscriptLayout.stickToBottomDistance)
            self.applyNearViewport()
            self.pinVisibleImages()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { self.scrollEnded() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            self.scrollEnded()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            self.isScrollingToTop = false
        }

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            self.isScrollingToTop = true
            return true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            self.isScrollingToTop = false
            self.anchor = .top
            self.settle()
            self.scrollEnded()
        }

        private func scrollEnded() {
            self.anchor = self.currentAnchor()
            self.schedulePrefetch()
        }

        /// The row at the middle of the viewport, or the bottom when the reader is at the end. The
        /// middle row is used because rows entering at the edges may still change height.
        private func currentAnchor(stickDistance: CGFloat = TranscriptLayout.stickToBottomDistance,
                                   allowTop: Bool = true) -> Anchor {
            guard let view = self.collectionView, !self.rows.isEmpty else { return .bottom }
            let offset = view.contentOffset.y
            if self.maxOffset - offset <= stickDistance { return .bottom }
            if allowTop, offset - self.minOffset <= 1 { return .top }
            guard let row = self.row(at: offset + view.bounds.height / 2) else { return .bottom }
            return .row(self.rows[row].id, self.tops[row] - offset)
        }

        private func restore(_ anchor: Anchor) {
            guard let view = self.collectionView else { return }
            let target: CGFloat
            switch anchor {
            case .bottom:
                target = self.maxOffset
            case .top:
                target = self.minOffset
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
    private weak var actions: TranscriptRowActions?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.contentView.addSubview(self.content)
        self.backgroundConfiguration = .clear()
        // One swipe per message; the row's buttons become its custom actions.
        self.isAccessibilityElement = true
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
        self.actions = actions
        self.content.apply(layout, actions: actions)
    }

    // Computed when VoiceOver asks, not on every layout, so scrolling pays nothing for them.
    override var accessibilityLabel: String? {
        get { self.content.layout?.accessibilityLabel }
        set {}
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let layout = self.content.layout else { return nil }
            var actions = TranscriptRowAccessibilityAction.actions(for: layout, actions: self.actions, anchor: self.content)
            var names = Set(actions.map(\.name))
            // The row's other buttons (disclosures, links, images, reaction chips), which a single
            // element would otherwise hide. The footers' own buttons are covered above.
            for control in Self.tapViews(in: self.content) where !names.contains(control.accessibilityText) {
                names.insert(control.accessibilityText)
                actions.append(.init(name: control.accessibilityText) { [weak control] in control?.onTap?() })
            }
            // Markdown links in the message text, which the single element hides too.
            for (title, url) in AccessibilityText.linkActions(Self.linkRuns(in: self.content)) {
                let name = L("Open \(title)")
                guard names.insert(name).inserted else { continue }
                actions.append(.init(name: name) { [weak renderer = self.actions] in renderer?.open(url) })
            }
            return actions.map { action in
                UIAccessibilityCustomAction(name: action.name) { _ in
                    action.perform()
                    return true
                }
            }
        }
        set {}
    }

    /// Every link run in the row's visible text, top to bottom (deduped and capped by the caller).
    private static func linkRuns(in view: UIView) -> [(text: String, url: URL)] {
        var runs: [(text: String, url: URL)] = []
        for subview in view.subviews where !subview.isHidden {
            if let text = subview as? UITextView {
                let storage = text.textStorage
                storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                    runs.append((storage.attributedSubstring(from: range).string, url))
                }
            } else {
                runs += Self.linkRuns(in: subview)
            }
        }
        return runs
    }

    private static func tapViews(in view: UIView) -> [TranscriptTapView] {
        var found: [TranscriptTapView] = []
        for subview in view.subviews where !subview.isHidden {
            if subview is TranscriptFooterView { continue }
            if let tap = subview as? TranscriptTapView, tap.onTap != nil, !tap.accessibilityText.isEmpty {
                found.append(tap)
            }
            found += Self.tapViews(in: subview)
        }
        return found
    }
}
#endif
