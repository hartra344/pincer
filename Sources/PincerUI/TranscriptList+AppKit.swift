#if os(macOS)
import AppKit
import PincerKit
import SwiftUI

/// Chat transcript backed by `NSTableView`. Rows are drawn natively from layouts computed by
/// `TranscriptRenderer`, so a row's height is known exactly before it's on screen. Only rows near
/// the viewport are laid out eagerly, the rest in idle slices, and the row the reader is looking
/// at stays put while history loads above it or a reply streams in below.
struct TranscriptList: NSViewRepresentable {
    let rows: [TranscriptRow]
    let context: TranscriptContext
    /// Extra space below the last row for content floating over the transcript (the composer).
    var bottomInset: CGFloat = 0
    /// Extra space above the first row, for a toolbar the transcript scrolls under.
    var topInset: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator(context: self.context) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(rows: self.rows, context: self.context, insets: (self.topInset, self.bottomInset))
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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
        private var anchor = Anchor.bottom
        private var isAdjusting = false
        private var lastOffset: CGFloat = 0
        private var isLiveScrolling = false
        private var prefetchScheduled = false
        private var clipSize = CGSize.zero
        private let renderer: TranscriptRenderer
        private weak var scrollView: NSScrollView?
        private weak var table: NSTableView?

        init(context: TranscriptContext) {
            self.context = context
            self.renderer = TranscriptRenderer(context: context)
            super.init()
            self.renderer.onInvalidate = { [weak self] ids, keepInPlace in
                self?.invalidate(ids, keepInPlace: keepInPlace)
            }
        }

        func makeScrollView() -> NSScrollView {
            let table = TranscriptListTableView()
            table.headerView = nil
            table.style = .plain
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .none
            table.allowsEmptySelection = true
            table.allowsTypeSelect = false
            table.gridStyleMask = []
            table.intercellSpacing = NSSize(width: 0, height: TranscriptLayout.rowSpacing)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.focusRingType = .none
            table.refusesFirstResponder = true
            let column = NSTableColumn(identifier: .init("row"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.dataSource = self
            table.delegate = self

            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: TranscriptLayout.verticalInset, left: 0,
                                                bottom: TranscriptLayout.verticalInset, right: 0)
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(self.clipChanged),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(self.clipChanged),
                                                   name: NSView.frameDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(self.liveScrollStarted),
                                                   name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            NotificationCenter.default.addObserver(self, selector: #selector(self.liveScrollEnded),
                                                   name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            self.scrollView = scroll
            self.table = table
            return scroll
        }

        // MARK: Data

        func update(rows newRows: [TranscriptRow], context: TranscriptContext, insets: (top: CGFloat, bottom: CGFloat)) {
            let contextChanged = context.differs(from: self.context)
            self.context = context
            self.renderer.update(context: context)
            guard let table, let scroll = self.scrollView else { return }
            let top = TranscriptLayout.verticalInset + max(0, insets.top)
            let bottom = TranscriptLayout.verticalInset + max(0, insets.bottom)
            if abs(scroll.contentInsets.top - top) > 0.5 || abs(scroll.contentInsets.bottom - bottom) > 0.5 {
                scroll.contentInsets.top = top
                scroll.contentInsets.bottom = bottom
                if !self.rows.isEmpty, !contextChanged { self.settle(changed: IndexSet()) }
            }
            if contextChanged {
                self.heights.removeAll()
                self.rows = []
            }
            guard newRows != self.rows else { return }
            let oldRows = self.rows
            self.rows = newRows
            self.index = Dictionary(newRows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

            if oldRows.isEmpty {
                self.anchor = .bottom
                table.reloadData()
                self.settle(changed: IndexSet())
                return
            }

            let oldById = Dictionary(oldRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let oldIds = oldRows.map(\.id)
            let newIds = newRows.map(\.id)
            if oldIds != newIds {
                var removals = IndexSet()
                var insertions = IndexSet()
                for change in newIds.difference(from: oldIds) {
                    switch change {
                    case let .remove(offset, _, _): removals.insert(offset)
                    case let .insert(offset, _, _): insertions.insert(offset)
                    }
                }
                if insertions.contains(where: { newRows[$0].isPendingSend }) { self.anchor = .bottom }
                self.withoutAnimation {
                    table.beginUpdates()
                    table.removeRows(at: removals, withAnimation: [])
                    table.insertRows(at: insertions, withAnimation: [])
                    table.endUpdates()
                }
            }

            // Rows whose content changed (a streaming reply, a tool finishing) are updated in
            // place; their old height stays as the estimate until they're measured again.
            var changed = IndexSet()
            for (row, item) in newRows.enumerated() {
                guard let old = oldById[item.id], old != item else { continue }
                self.heights[item.id]?.measured = false
                changed.insert(row)
            }
            self.settle(changed: changed)
        }

        /// Rows whose layout changed without the rows themselves changing: an image arrived, a
        /// card opened, a setting changed. `keepInPlace` is a row the reader just clicked, which
        /// should stay where it is on screen while it grows or shrinks below that point.
        private func invalidate(_ ids: Set<String>?, keepInPlace: String?) {
            guard let table else { return }
            var changed = IndexSet()
            if let ids {
                for id in ids {
                    guard let row = self.index[id] else { continue }
                    self.heights[id]?.measured = false
                    changed.insert(row)
                }
            } else {
                for id in self.heights.keys { self.heights[id]?.measured = false }
                changed = IndexSet(integersIn: 0..<self.rows.count)
            }
            guard !changed.isEmpty else { return }
            if let keepInPlace, let row = self.index[keepInPlace], let clip = self.scrollView?.contentView {
                self.anchor = .row(keepInPlace, table.rect(ofRow: row).minY - clip.bounds.minY)
                self.settle(changed: changed)
                self.anchor = self.currentAnchor()
            } else {
                self.settle(changed: changed)
            }
        }

        /// Measures rows around the viewport, applies any height changes and puts the reader back
        /// where they were.
        private func settle(changed: IndexSet) {
            guard let table else { return }
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            // Jump to the anchor first so the rows measured are the ones about to be on screen.
            self.restore(self.anchor)
            var resized = self.measureAroundViewport()
            resized.formUnion(changed)
            if !resized.isEmpty {
                self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: resized) }
            }
            self.restore(self.anchor)
            self.refreshVisibleCells()
            self.schedulePrefetch()
        }

        /// Brings cells on screen up to date with their current layout. Cells skip layouts they
        /// already show, so this is cheap when nothing changed.
        private func refreshVisibleCells() {
            guard let table else { return }
            let width = self.width
            guard width > 40 else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location..<min(visible.location + visible.length, self.rows.count) {
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell else { continue }
                cell.apply(self.renderer.layout(for: self.rows[row], width: width), actions: self.renderer)
            }
        }

        // MARK: Heights

        /// The table's single column always spans the clip view.
        private var width: CGFloat {
            self.scrollView?.contentView.bounds.width ?? 0
        }

        private func measure(_ row: TranscriptRow, width: CGFloat) -> CGFloat {
            max(1, self.renderer.layout(for: row, width: width).height)
        }

        /// Measures unmeasured rows from a screen above the viewport to a screen below it, so rows
        /// have their real height before they scroll into view. Returns the rows that changed.
        private func measureAroundViewport() -> IndexSet {
            guard let table, let clip = self.scrollView?.contentView, !self.rows.isEmpty else { return [] }
            let width = self.width
            guard width > 40 else { return [] }
            let visible = clip.bounds
            let around = visible.insetBy(dx: 0, dy: -max(visible.height, 200))
            let range = table.rows(in: around)
            guard range.length > 0 else { return [] }
            var changed = IndexSet()
            for row in range.location..<min(range.location + range.length, self.rows.count) {
                let item = self.rows[row]
                if let height = self.heights[item.id], height.measured, height.width == width { continue }
                let old = self.heights[item.id]?.value
                let value = self.measure(item, width: width)
                self.heights[item.id] = Height(value: value, width: width, measured: true)
                if old.map({ abs($0 - value) > 0.5 }) ?? true { changed.insert(row) }
            }
            return changed
        }

        /// Measures the rest of the transcript in small slices while the reader isn't scrolling,
        /// nearest rows first, so heights are final before rows scroll into view. Correcting a
        /// height mid-scroll means moving the scroll position under the reader's fingers.
        private func schedulePrefetch() {
            guard !self.prefetchScheduled else { return }
            self.prefetchScheduled = true
            DispatchQueue.main.async { [weak self] in self?.prefetchStep() }
        }

        private func prefetchStep() {
            self.prefetchScheduled = false
            guard !self.isLiveScrolling, let table, let clip = self.scrollView?.contentView, !self.rows.isEmpty else { return }
            let width = self.width
            guard width > 40 else { return }
            var center = table.row(at: NSPoint(x: 1, y: clip.bounds.midY))
            if center < 0 { center = self.rows.count - 1 }
            let deadline = Date().addingTimeInterval(0.006)
            var changed = IndexSet()
            var remaining = false
            // Walk outward from the viewport: below, above, below, above…
            var below = center, above = center - 1
            while below < self.rows.count || above >= 0 {
                for row in [below, above] where row >= 0 && row < self.rows.count {
                    let item = self.rows[row]
                    if let height = self.heights[item.id], height.measured, height.width == width { continue }
                    if Date() >= deadline { remaining = true; break }
                    let old = self.heights[item.id]?.value
                    let value = self.measure(item, width: width)
                    self.heights[item.id] = Height(value: value, width: width, measured: true)
                    if old.map({ abs($0 - value) > 0.5 }) ?? true { changed.insert(row) }
                }
                if remaining { break }
                below += 1
                above -= 1
            }
            if !changed.isEmpty {
                self.isAdjusting = true
                self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: changed) }
                self.restore(self.anchor)
                self.isAdjusting = false
            }
            if remaining { self.schedulePrefetch() }
        }

        @objc private func liveScrollStarted() {
            self.isLiveScrolling = true
        }

        @objc private func liveScrollEnded() {
            self.isLiveScrolling = false
            self.schedulePrefetch()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < self.rows.count else { return 1 }
            let item = self.rows[row]
            if let height = self.heights[item.id] { return height.value }
            let estimate = TranscriptLayout.estimatedHeight(item, width: self.width)
            self.heights[item.id] = Height(value: estimate, width: self.width, measured: false)
            return estimate
        }

        // MARK: Cells

        func numberOfRows(in tableView: NSTableView) -> Int { self.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = self.rows[row]
            let cell = tableView.makeView(withIdentifier: TranscriptCell.reuseIdentifier, owner: nil) as? TranscriptCell
                ?? TranscriptCell()
            cell.apply(self.renderer.layout(for: item, width: self.width), actions: self.renderer)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        // MARK: Scrolling

        @objc private func clipChanged() {
            guard let clip = self.scrollView?.contentView else { return }
            if clip.frame.size != self.clipSize {
                // Window resize or the composer growing: keep the same message in view, and
                // re-measure what's on screen at the new width.
                self.clipSize = clip.frame.size
                self.settle(changed: IndexSet())
                return
            }
            let offset = clip.bounds.minY
            defer { self.lastOffset = offset }
            guard !self.isAdjusting else { return }
            // Scrolling up leaves the bottom right away; only scrolling down re-sticks early.
            let movingUp = offset < self.lastOffset - 0.5
            self.anchor = self.currentAnchor(stickDistance: movingUp ? 1 : TranscriptLayout.stickToBottomDistance)
            let resized = self.measureAroundViewport()
            guard let table, !resized.isEmpty else { return }
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: resized) }
            self.restore(self.anchor)
        }

        private var contentHeight: CGFloat {
            guard let table, !self.rows.isEmpty else { return 0 }
            return table.rect(ofRow: self.rows.count - 1).maxY
        }

        private func offsetRange() -> ClosedRange<CGFloat> {
            guard let scroll = self.scrollView else { return 0...0 }
            let top = -scroll.contentInsets.top
            let bottom = max(top, self.contentHeight + scroll.contentInsets.bottom - scroll.contentView.bounds.height)
            return top...bottom
        }

        /// The row at the middle of the viewport, or the bottom when the reader is at the end. The
        /// middle row is used because rows entering at the edges may still change height.
        private func currentAnchor(stickDistance: CGFloat = TranscriptLayout.stickToBottomDistance) -> Anchor {
            guard let table, let clip = self.scrollView?.contentView, !self.rows.isEmpty else { return .bottom }
            let bounds = clip.bounds
            if self.offsetRange().upperBound - bounds.minY <= stickDistance { return .bottom }
            var row = table.row(at: NSPoint(x: 1, y: bounds.midY))
            if row < 0 { row = bounds.midY < 0 ? 0 : self.rows.count - 1 }
            return .row(self.rows[row].id, table.rect(ofRow: row).minY - bounds.minY)
        }

        private func restore(_ anchor: Anchor) {
            guard let table, let scroll = self.scrollView else { return }
            let range = self.offsetRange()
            let target: CGFloat
            switch anchor {
            case .bottom:
                target = range.upperBound
            case let .row(id, offset):
                guard let row = self.index[id] else {
                    self.anchor = self.currentAnchor()
                    return
                }
                target = min(max(table.rect(ofRow: row).minY - offset, range.lowerBound), range.upperBound)
            }
            let clip = scroll.contentView
            guard abs(clip.bounds.minY - target) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
            scroll.reflectScrolledClipView(clip)
        }

        private func withoutAnimation(_ body: () -> Void) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            body()
            NSAnimationContext.endGrouping()
        }
    }
}

/// Lets clicks reach the row's content (buttons, links, text selection) instead of being taken
/// for row selection.
private final class TranscriptListTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

private final class TranscriptCell: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TranscriptCell")

    private let content = TranscriptRowView()
    private var serial: Int?

    init() {
        super.init(frame: .zero)
        self.identifier = Self.reuseIdentifier
        self.addSubview(self.content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func apply(_ layout: TranscriptRowLayout, actions: TranscriptRowActions) {
        // Top-aligned at the layout's own size, so a row briefly taller than its table row
        // (between a change and the table catching up) grows downward.
        let frame = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        if self.content.frame != frame { self.content.frame = frame }
        guard layout.serial != self.serial else { return }
        self.serial = layout.serial
        self.content.apply(layout, actions: actions)
        self.setAccessibilityElement(false)
        self.content.setAccessibilityLabel(layout.accessibilityLabel)
    }
}
#endif
