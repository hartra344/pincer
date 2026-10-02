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
    let isConnected: Bool
    /// Extra space below the last row for content floating over the transcript (the composer).
    var bottomInset: CGFloat = 0
    /// Extra space above the first row, for a toolbar the transcript scrolls under.
    var topInset: CGFloat = 0
    /// Find in chat's matches to highlight, and the selected one to scroll to.
    var highlight = TranscriptHighlight()
    /// A message to scroll to and flash, e.g. from a `pincer://` link.
    var jump: TranscriptJump?
    /// Told how far the reader is from the latest message and whether the list follows the bottom;
    /// runs the scroll-to-bottom button's scroll (#439).
    var bottomState: TranscriptBottomState?
    /// Go ▸ Previous/Next Message for this list (#195).
    var navigator: TranscriptNavigator?

    func makeCoordinator() -> Coordinator { Coordinator(context: self.context) }

    func makeUIView(context: Context) -> UICollectionView {
        context.coordinator.makeCollectionView()
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        context.coordinator.attach(self.bottomState)
        context.coordinator.update(rows: self.rows, context: self.context,
                                   insets: (self.topInset, self.bottomInset), isConnected: self.isConnected)
        context.coordinator.apply(self.highlight)
        context.coordinator.apply(self.jump)
        context.coordinator.install(self.navigator)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        let controller: TranscriptListController
        /// Top of each row in content coordinates, and the total content height.
        fileprivate private(set) var tops: [CGFloat] = []
        fileprivate private(set) var contentHeight: CGFloat = 0
        /// Ids whose height value changed since the offsets were last built.
        private var dirtyHeights = Set<String>()
        private var isAdjusting = false
        private var isScrollingToTop = false
        private var lastOffset: CGFloat = 0
        private weak var collectionView: TranscriptCollectionView?

        var renderer: TranscriptRenderer { self.controller.renderer }
        var prefetchStats: (steps: Int, rowsMeasured: Int, seconds: Double) { self.controller.prefetchStats }
        var premeasureStats: PremeasureStats { self.controller.premeasureStats }
        /// Whether the list is following the bottom (#335: the open chat may be trimmed then).
        var isAnchoredAtBottom: Bool { self.controller.isAnchoredAtBottom }

        private var rows: [TranscriptRow] { self.controller.rows }

        init(context: TranscriptContext) {
            self.controller = TranscriptListController(context: context, prefetchBudget: 0.004)
            super.init()
            self.controller.host = self
        }

        func makeCollectionView() -> UICollectionView {
            let layout = TranscriptCollectionLayout()
            layout.coordinator = self
            let view = TranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
            view.coordinator = self
            view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UICollectionView, _) in
                self?.renderer.appearanceChanged()
            }
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
            view.accessibilityCustomRotors = self.makeRotors()
            return view
        }

        // MARK: Data

        func update(rows newRows: [TranscriptRow], context: TranscriptContext,
                    insets: (top: CGFloat, bottom: CGFloat), isConnected: Bool = true) {
            let contextChanged = self.controller.beginUpdate(context: context, rowCount: newRows.count)
            var acceptedRows = false
            defer {
                self.controller.revealPending()
                if acceptedRows { self.controller.gatewayConnectionChanged(isConnected: isConnected) }
                self.controller.loadOlderIfShown()
                self.reportPosition()
            }
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
            let update = self.controller.accept(newRows, contextChanged: contextChanged)
            acceptedRows = true
            switch update {
            case .unchanged:
                return
            case .tail:
                self.settle()
            case .initial:
                self.rebuildOffsets()
                self.reload(view)
                self.settle()
            case let .rows(_, oldIds):
                // Rows only come and go when a message is sent or arrives, or history loads, so a
                // reload (which re-dequeues the few cells on screen) is cheap enough.
                if oldIds != nil {
                    self.rebuildOffsets()
                    self.reload(view)
                }
                self.settle()
            }
        }

        private func reload(_ view: UICollectionView) {
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            UIView.performWithoutAnimation {
                view.reloadData()
            }
        }

        /// Measures rows around the viewport, applies any height changes, puts the reader back
        /// where they were and brings the cells on screen up to date.
        fileprivate func settle() {
            guard let view = self.collectionView else { return }
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            // Jump to the anchor first so the rows measured are the ones about to be on screen.
            self.restore(self.controller.anchor)
            // Measuring rows above the anchor moves the viewport over rows that weren't measured
            // yet, so go again until the rows on screen are all measured.
            var passes = 0
            while passes < 4 {
                let changed = self.controller.measureAroundViewport()
                guard !changed.isEmpty else { break }
                self.markDirty(changed)
                self.applyHeights()
                self.restore(self.controller.anchor)
                passes += 1
            }
            self.restore(self.controller.anchor)
            view.layoutIfNeeded()
            self.refreshVisibleCells()
            self.controller.schedulePrefetch()
        }

        private func markDirty(_ rows: IndexSet) {
            for row in rows where row < self.rows.count { self.dirtyHeights.insert(self.rows[row].id) }
        }

        private func refreshVisibleCells() {
            guard let view = self.collectionView else { return }
            let width = self.width
            guard width > 40 else { return }
            for path in view.indexPathsForVisibleItems where path.item < self.rows.count {
                let layout = self.renderer.layout(for: self.rows[path.item], width: width)
                self.controller.correctHeight(self.rows[path.item].id, width: width, height: layout.height)
                guard let cell = view.cellForItem(at: path) as? TranscriptCell else { continue }
                cell.apply(layout, actions: self.renderer)
            }
            self.controller.pinVisibleImages()
        }

        /// The viewport changed size: rotation, split view, the keyboard or the composer.
        fileprivate func viewportChanged() {
            self.settle()
        }

        func apply(_ jump: TranscriptJump?) { self.controller.apply(jump) }

        func apply(_ highlight: TranscriptHighlight) { self.controller.apply(highlight) }

        func prefetchStep() { self.controller.prefetchStep() }

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

        private func rebuildOffsets() {
            var tops: [CGFloat] = []
            tops.reserveCapacity(self.rows.count)
            var y: CGFloat = 0
            let width = self.width
            for row in self.rows.indices {
                if row > 0 { y += TranscriptLayout.rowSpacing }
                tops.append(y)
                y += self.controller.height(at: row, width: width)
            }
            self.tops = tops
            self.contentHeight = y
            self.dirtyHeights.removeAll()
        }

        fileprivate func frame(at row: Int) -> CGRect {
            let insets = self.horizontalInsets
            let height = self.controller.heights[self.rows[row].id]?.value ?? 1
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
                let new = self.controller.height(at: self.rows.count - 1, width: self.width)
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

        // MARK: Cells

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            self.rows.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TranscriptCell.reuseIdentifier, for: indexPath)
            if let cell = cell as? TranscriptCell, indexPath.item < self.rows.count {
                let item = self.rows[indexPath.item]
                let layout = self.renderer.layout(for: item, width: self.width)
                self.controller.correctHeight(item.id, width: self.width, height: layout.height)
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
            self.reportPosition()
            // Only the reader moves the anchor: layout changes and inset changes keep it.
            guard !self.isAdjusting,
                  scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || self.isScrollingToTop
            else { return }
            // The status-bar scroll to top is an animation that setting the offset would cut
            // short; it finishes at the top and is settled once it gets there.
            guard !self.isScrollingToTop else { return }
            self.controller.readerScrolled(movingUp: TranscriptListController.isMovingUp(from: self.lastOffset, to: offset))
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
            self.controller.anchor = .top
            self.settle()
            self.scrollEnded()
        }

        private func scrollEnded() {
            self.controller.anchor = self.controller.currentAnchor()
            self.controller.schedulePrefetch()
        }

        // MARK: Scroll to bottom

        func attach(_ state: TranscriptBottomState?) {
            self.controller.attach(state) { [weak self] in self?.scrollToBottom() }
        }

        private func reportPosition() {
            guard let model = self.controller.bottom, let view = self.collectionView else { return }
            let insets = view.adjustedContentInset
            model.report(distance: self.rows.isEmpty ? 0 : self.maxOffset - view.contentOffset.y,
                         viewport: view.bounds.height - insets.top - insets.bottom, lastRowId: self.rows.last?.id)
        }

        /// Scrolls to the latest message and follows it again. From far up it jumps to a screen
        /// above the end first, so the animation doesn't lay out the whole history on the way.
        func scrollToBottom() {
            guard let view = self.collectionView, !self.rows.isEmpty else { return }
            self.isScrollingToTop = false
            self.controller.anchor = .bottom
            let target = self.maxOffset
            let height = view.bounds.height
            let animated = !UIAccessibility.isReduceMotionEnabled
            if !animated || target - view.contentOffset.y > height * 2 {
                self.isAdjusting = true
                view.contentOffset.y = animated ? target - height : target
                self.isAdjusting = false
                if !animated { self.settle() }
            }
            if animated { view.setContentOffset(CGPoint(x: view.contentOffset.x, y: self.maxOffset), animated: true) }
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            // Rows measured on the way may have moved the end; land on it exactly.
            if self.controller.anchor == .bottom { self.settle() }
            self.controller.schedulePrefetch()
        }

        private func restore(_ anchor: TranscriptAnchor) {
            guard let view = self.collectionView, let target = self.controller.restoreTarget(anchor) else { return }
            guard abs(view.contentOffset.y - target) > 0.5 else { return }
            let wasAdjusting = self.isAdjusting
            self.isAdjusting = true
            view.contentOffset.y = target
            self.isAdjusting = wasAdjusting
        }
    }
}

extension TranscriptList.Coordinator: TranscriptListHost {
    var layoutWidth: CGFloat { self.width }

    var isLayoutFrozen: Bool { false }

    var isScrolling: Bool {
        guard let view = self.collectionView else { return true }
        return view.isTracking || view.isDecelerating || self.isScrollingToTop
    }

    var viewport: TranscriptViewport? {
        guard let view = self.collectionView else { return nil }
        return TranscriptViewport(offset: view.contentOffset.y, height: view.bounds.height, range: self.minOffset...self.maxOffset)
    }

    func rowTop(_ row: Int) -> CGFloat? {
        row < self.tops.count ? self.tops[row] : nil
    }

    func row(atContentY y: CGFloat) -> Int? { self.row(at: y) }

    var visibleRows: ClosedRange<Int>? {
        guard let view = self.collectionView, view.bounds.height > 0,
              let first = self.row(at: view.contentOffset.y),
              let last = self.row(at: view.contentOffset.y + view.bounds.height) else { return nil }
        return first...last
    }

    func rowWindow(screens: CGFloat, minimum: CGFloat) -> (range: ClosedRange<Int>, center: Int)? {
        guard let view = self.collectionView, view.bounds.height > 0, !self.rows.isEmpty else { return nil }
        let visible = CGRect(origin: view.contentOffset, size: view.bounds.size)
        let around = visible.insetBy(dx: 0, dy: -max(visible.height * screens, minimum))
        guard let first = self.row(at: around.minY), let last = self.row(at: around.maxY),
              let center = self.row(at: visible.midY) else { return nil }
        return (first...last, center)
    }

    func heightsChanged(_ rows: IndexSet) {
        self.markDirty(rows)
        guard !self.dirtyHeights.isEmpty else { return }
        let wasAdjusting = self.isAdjusting
        self.isAdjusting = true
        self.applyHeights()
        self.restore(self.controller.anchor)
        self.isAdjusting = wasAdjusting
    }

    func settle(changed: IndexSet) { self.settle() }

    // MARK: Message navigation and rotors (#195)

    func install(_ navigator: TranscriptNavigator?) {
        navigator?.move = { [weak self] forward in self?.navigate(forward: forward) }
    }

    /// Moves the current message on, scrolls it into view and moves VoiceOver to it.
    private func navigate(forward: Bool) {
        guard let row = self.controller.moveNavigation(forward: forward), let cell = self.showCell(at: row) else { return }
        UIAccessibility.post(notification: .layoutChanged, argument: cell)
    }

    /// Scrolls to a row and returns its cell, which the scroll has just brought on screen.
    private func showCell(at row: Int) -> TranscriptCell? {
        guard let view = self.collectionView else { return nil }
        self.controller.scrollIntoView(row)
        view.layoutIfNeeded()
        return view.cellForItem(at: IndexPath(item: row, section: 0)) as? TranscriptCell
    }

    private func makeRotors() -> [UIAccessibilityCustomRotor] {
        let kinds: [(String, TranscriptNavKind)] = [
            (L("Messages"), .message), (L("Replies"), .reply), (L("Your Messages"), .user), (L("Tool Calls"), .tool),
        ]
        return kinds.map { name, kind in
            UIAccessibilityCustomRotor(name: name) { [weak self] predicate in
                self?.rotorResult(kind: kind, predicate: predicate)
            }
        }
    }

    /// The next or previous row of `kind`, searched in every row (not only the windowed cells).
    private func rotorResult(kind: TranscriptNavKind, predicate: UIAccessibilityCustomRotorSearchPredicate)
        -> UIAccessibilityCustomRotorItemResult? {
        var from: Int?
        if let cell = predicate.currentItem.targetElement as? UICollectionViewCell,
           let path = self.collectionView?.indexPath(for: cell) { from = path.item }
        let forward = predicate.searchDirection == .next
        guard let row = self.controller.adjacentRow(from: from, forward: forward, kind: kind),
              let cell = self.showCell(at: row) else { return nil }
        self.controller.navigationRowId = self.rows[row].id
        return UIAccessibilityCustomRotorItemResult(targetElement: cell, targetRange: nil)
    }

    /// Scrolls so the selected match (or the top of its row) sits a little above the middle
    /// of the visible area, clear of the bars and chrome floating over the transcript.
    func reveal(_ id: String) {
        guard let view = self.collectionView, let result = self.controller.prepareReveal(id) else { return }
        if result.moved {
            self.dirtyHeights.insert(id)
            self.applyHeights()
        }
        let insets = view.adjustedContentInset
        self.controller.anchor = TranscriptListController.revealAnchor(
            id: id, insetTop: insets.top, visibleHeight: view.bounds.height - insets.top - insets.bottom,
            matchY: result.layout.matchY, rowHeight: result.layout.height)
        self.settle()
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
            for action in AccessibilityText.linkActionsWithWebHosts(Self.linkRuns(in: self.content)) {
                let name: String
                if let host = action.webHost {
                    name = action.title.map { L("Open \($0) on \(host)") } ?? L("Open \(host)")
                } else if let title = action.title {
                    name = L("Open \(title)")
                } else {
                    continue
                }
                guard names.insert(name).inserted else { continue }
                actions.append(.init(name: name) { [weak renderer = self.actions] in renderer?.open(action.url) })
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
    private static func linkRuns(in view: UIView) -> [AccessibilityText.LinkActionRun] {
        var runs: [AccessibilityText.LinkActionRun] = []
        for subview in view.subviews where !subview.isHidden {
            if let text = subview as? UITextView {
                let storage = text.textStorage
                storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                    guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                    let host = storage.attribute(TranscriptWebSearchAccessibility.host, at: range.location, effectiveRange: nil) as? String
                    runs.append(.init(text: storage.attributedSubstring(from: range).string, url: url, webHost: host))
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
