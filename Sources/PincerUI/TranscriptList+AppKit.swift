#if os(macOS)
import AppKit
import os
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
    /// Find in chat's matches to highlight, and the selected one to scroll to.
    var highlight = TranscriptHighlight()
    /// A message to scroll to and flash, e.g. from a `pincer://` link.
    var jump: TranscriptJump?
    /// Told how far the reader is from the latest message; runs the scroll-to-bottom button's scroll.
    var scrollToBottom: ScrollToBottomModel?
    /// Told (on a later main-queue turn) whenever the list starts or stops following the bottom.
    var bottomAnchorChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(context: self.context) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.attach(self.scrollToBottom)
        context.coordinator.bottomAnchorChanged = self.bottomAnchorChanged
        context.coordinator.update(rows: self.rows, context: self.context, insets: (self.topInset, self.bottomInset))
        context.coordinator.apply(self.highlight)
        context.coordinator.apply(self.jump)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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
        private var anchor = Anchor.bottom {
            didSet {
                guard (oldValue == .bottom) != (self.anchor == .bottom), let report = self.bottomAnchorChanged else { return }
                let atBottom = self.anchor == .bottom
                DispatchQueue.main.async { report(atBottom) }
            }
        }
        var bottomAnchorChanged: ((Bool) -> Void)?
        /// Whether the list is following the bottom (#335: the open chat may be trimmed then).
        var isAnchoredAtBottom: Bool { self.anchor == .bottom }
        private var isAdjusting = false
        private var lastOffset: CGFloat = 0
        private var isLiveScrolling = false
        private var prefetchScheduled = false
        private var scrollMeasureScheduled = false
        private var queue = TranscriptMeasureQueue()
        private var queueWidth: CGFloat = 0
        private var pendingFixes = IndexSet()
        private var fixesScheduled = false
        /// Time spent measuring rows in idle slices and scroll callbacks, for the probe.
        var prefetchStats: (steps: Int, rowsMeasured: Int, seconds: Double) = (0, 0, 0)
        /// Rows prepared on the worker, and text measured there; separate from `prefetchStats`.
        private let premeasure = TranscriptPremeasureDriver()
        var premeasureStats: PremeasureStats { self.premeasure.stats }
        private var clipSize = CGSize.zero
        private var freeze = TranscriptWidthFreeze()
        private var thawItem: DispatchWorkItem?
        private var frozenSignpost: OSSignpostIntervalState?
        private weak var observedWindow: NSWindow?
        private var windowObserver: NSObjectProtocol?

        /// Whether layout is holding the previous width while the clip view's width animates.
        var isWidthFrozen: Bool { self.freeze.isFrozen }
        /// Thaws so far and the last one's relayout (layout builds, rows measured, build count after
        /// it), for the probe: a stalled run loop can thaw mid-slide, so timing can't tell them apart.
        private(set) var thawStats: (count: Int, builds: Int, rowsMeasured: Int, buildsAfter: Int) = (0, 0, 0, 0)
        let renderer: TranscriptRenderer
        private weak var scrollView: NSScrollView?
        private weak var table: NSTableView?

        init(context: TranscriptContext) {
            self.context = context
            self.renderer = TranscriptRenderer(context: context)
            super.init()
            self.premeasure.currentWidth = { [weak self] in self?.width ?? 0 }
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

            let scroll = TranscriptScrollView()
            scroll.onWindowChange = { [weak self] window in self?.observe(window) }
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
            defer {
                self.revealPending()
                self.loadOlderIfShown()
                self.reportPosition()
            }
            if newRows.count != self.rows.count { self.olderRowWasVisible = false }
            guard let table, let scroll = self.scrollView else { return }
            let top = TranscriptLayout.verticalInset + max(0, insets.top)
            let bottom = TranscriptLayout.verticalInset + max(0, insets.bottom)
            if abs(scroll.contentInsets.top - top) > 0.5 || abs(scroll.contentInsets.bottom - bottom) > 0.5 {
                scroll.contentInsets.top = top
                scroll.contentInsets.bottom = bottom
                if !self.rows.isEmpty, !contextChanged { self.settle(changed: IndexSet()) }
            }
            if contextChanged {
                self.premeasure.cancelAll()
                self.heights.removeAll()
                self.rows = []
            }
            if case .top = self.anchor, newRows.first?.id != self.rows.first?.id {
                // Rows arriving above: keep reading the same row instead of following the top.
                self.anchor = self.currentAnchor(allowTop: false)
            }
            // Streaming: same ids, only the last row differs. One pass, no diffing.
            if let last = newRows.last, self.rows.count == newRows.count, self.rows.last?.id == last.id,
               self.rows.dropLast() == newRows.dropLast() {
                guard self.rows[self.rows.count - 1] != last else { return }
                self.rows[self.rows.count - 1] = last
                self.heights[last.id]?.measured = false
                self.queue.markUnmeasured(newRows.count - 1)
                self.settle(changed: IndexSet(integer: newRows.count - 1))
                return
            }
            guard newRows != self.rows else { return }
            let oldRows = self.rows
            self.rows = newRows
            self.index = Dictionary(newRows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

            if oldRows.isEmpty {
                self.anchor = .bottom
                self.rebuildQueue()
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
                if newIds.count > oldIds.count, newIds.suffix(oldIds.count).elementsEqual(oldIds) {
                    // Older history arrived above: no need to diff thousands of rows.
                    insertions = IndexSet(integersIn: 0..<(newIds.count - oldIds.count))
                } else if oldIds.count > newIds.count, oldIds.suffix(newIds.count).elementsEqual(newIds) {
                    // Trimmed back to the window (#335): diffing away thousands of rows would stall.
                    removals = IndexSet(integersIn: 0..<(oldIds.count - newIds.count))
                    for id in oldIds.prefix(oldIds.count - newIds.count) { self.heights.removeValue(forKey: id) }
                } else {
                    for change in newIds.difference(from: oldIds) {
                        switch change {
                        case let .remove(offset, _, _): removals.insert(offset)
                        case let .insert(offset, _, _): insertions.insert(offset)
                        }
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
            self.rebuildQueue()
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
                    self.queue.markUnmeasured(row)
                    changed.insert(row)
                }
            } else {
                self.premeasure.cancelAll()
                for id in self.heights.keys { self.heights[id]?.measured = false }
                self.queue.markAllUnmeasured(count: self.rows.count)
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
            let signpost = TranscriptSignposts.begin("Settle")
            defer { TranscriptSignposts.end("Settle", signpost) }
            guard let table else { return }
            // Remember the size layout starts from, so the first width change can freeze at it.
            if self.clipSize == .zero, let clip = self.scrollView?.contentView { self.clipSize = clip.frame.size }
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            // Jump to the anchor first so the rows measured are the ones about to be on screen.
            self.restore(self.anchor)
            // Measuring rows above the anchor moves the viewport over rows that weren't measured
            // yet, so go again until the rows on screen are all measured.
            var resized = changed
            for _ in 0..<4 {
                // Frozen: the rows around the viewport are measured once, at the final width.
                if !self.freeze.isFrozen { resized.formUnion(self.measureAroundViewport()) }
                if resized.isEmpty { break }
                self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: resized) }
                resized = []
                self.restore(self.anchor)
            }
            // The table's frame catches up with the new row heights lazily; without this the last
            // restore clamps against stale content height and a bottom anchor ends short.
            table.layoutSubtreeIfNeeded()
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
            let range = visible.location..<min(visible.location + visible.length, self.rows.count)
            for row in range {
                let layout = self.renderer.layout(for: self.rows[row], width: width)
                self.correctHeight(self.rows[row].id, width: width, height: layout.height)
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell else { continue }
                cell.apply(layout, actions: self.renderer)
            }
            self.renderer.pinImages(of: self.rows[range], width: width)
        }

        /// Highlights Find's matches and scrolls the selected one into view when asked to.
        private var lastJump: UUID?

        func apply(_ jump: TranscriptJump?) {
            guard let jump, jump.id != self.lastJump else { return }
            self.lastJump = jump.id
            self.renderer.showOriginal(jump.messageId, missingNotice: PincerRoute.Notice.unknownMessage)
        }

        func apply(_ highlight: TranscriptHighlight) {
            if highlight != self.renderer.highlight { self.premeasure.cancelAll() }
            guard let id = self.renderer.update(highlight: highlight) else { return }
            self.reveal(id)
        }

        /// Scrolls so the selected match (or the top of its row) sits a little above the middle
        /// of the visible area, clear of the chrome floating over the transcript.
        private func reveal(_ id: String) {
            guard let table, let scroll = self.scrollView, let row = self.index[id] else { return }
            let width = self.width
            guard width > 40 else { return }
            let layout = self.renderer.layout(for: self.rows[row], width: width)
            let old = self.heights[id]?.value
            self.heights[id] = Height(value: max(1, layout.height), width: width, measured: true)
            self.syncQueueWidth(width)
            self.queue.markMeasured(row)
            if old.map({ abs($0 - layout.height) > 0.5 }) ?? true {
                self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: [row]) }
            }
            let insets = scroll.contentInsets
            let visible = max(scroll.contentView.bounds.height - insets.top - insets.bottom, 1)
            let y = min(layout.matchY ?? 0, layout.height)
            self.anchor = .row(id, insets.top + visible * 0.4 - y)
            self.settle(changed: IndexSet())
        }

        // MARK: Heights

        /// The table's single column always spans the clip view.
        private var width: CGFloat {
            self.freeze.frozenWidth ?? self.scrollView?.contentView.bounds.width ?? 0
        }

        // MARK: Width freeze

        /// Thaws right away, running the one relayout at the real width. For tests.
        func thawWidthNow() {
            self.thawItem?.cancel()
            self.thawItem = nil
            guard self.freeze.thaw() != nil else { return }
            if let state = self.frozenSignpost { TranscriptSignposts.end("WidthFrozen", state) }
            self.frozenSignpost = nil
            TranscriptSignposts.event("Thaw")
            self.premeasure.cancelAll()
            if let clip = self.scrollView?.contentView { self.clipSize = clip.frame.size }
            self.queueWidth = 0
            let builds = self.renderer.layoutBuildCount, measured = self.prefetchStats.rowsMeasured
            // The anchor from before the freeze is kept, so the reader stays on the same message.
            self.settle(changed: IndexSet())
            self.thawStats = (self.thawStats.count + 1, self.renderer.layoutBuildCount - builds,
                              self.prefetchStats.rowsMeasured - measured, self.renderer.layoutBuildCount)
        }

        private func widthDidChange(from old: CGFloat, to new: CGFloat) {
            let wasFrozen = self.freeze.isFrozen
            // While frozen `old` is the live width, not the frozen one; the freeze keeps the first.
            guard self.freeze.widthChanged(from: old, to: new, at: ProcessInfo.processInfo.systemUptime) else { return }
            if !wasFrozen {
                self.frozenSignpost = TranscriptSignposts.begin("WidthFrozen")
                self.premeasure.cancelAll()
            }
            self.scheduleThaw(after: TranscriptWidthFreeze.quietInterval)
        }

        private func scheduleThaw(after delay: TimeInterval) {
            self.thawItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.freeze.isFrozen else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.freeze.isQuiet(at: now) {
                    self.thawWidthNow()
                } else {
                    self.scheduleThaw(after: self.freeze.remainingQuiet(at: now))
                }
            }
            self.thawItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        fileprivate func observe(_ window: NSWindow?) {
            guard window !== self.observedWindow else { return }
            if let old = self.windowObserver { NotificationCenter.default.removeObserver(old) }
            self.windowObserver = nil
            self.observedWindow = window
            guard let window else { return }
            self.windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.thawWidthNow() }
            }
        }

        private func measure(_ row: TranscriptRow, width: CGFloat) -> CGFloat {
            max(1, self.renderer.layout(for: row, width: width).height)
        }

        private func syncQueueWidth(_ width: CGFloat) {
            guard width != self.queueWidth else { return }
            self.queueWidth = width
            self.premeasure.cancelAll()
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
            guard let table else { return [] }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return [] }
            return Set((visible.location..<min(visible.location + visible.length, self.rows.count)).map { self.rows[$0].id })
        }

        /// The rows within `screens` viewport heights of the viewport, and the one in the middle.
        private func window(screens: CGFloat, minimum: CGFloat = 200) -> (range: ClosedRange<Int>, center: Int)? {
            guard let table, let clip = self.scrollView?.contentView, !self.rows.isEmpty else { return nil }
            let visible = clip.bounds
            let around = visible.insetBy(dx: 0, dy: -max(visible.height * screens, minimum))
            let range = table.rows(in: around)
            guard let window = TranscriptMeasureQueue.window(in: range.location..<(range.location + range.length),
                                                             count: self.rows.count) else { return nil }
            var center = table.row(at: NSPoint(x: 1, y: visible.midY))
            if center < 0 { center = self.rows.count - 1 }
            return (window, center)
        }

        /// Measures `rows`, stopping at `deadline` if there is one. Returns the rows whose height
        /// changed and whether it stopped early.
        private func measure(_ rows: [Int], width: CGFloat, deadline: Date?) -> (changed: IndexSet, stopped: Bool) {
            var changed = IndexSet()
            var measured = 0
            var stopped = false
            for row in rows {
                if let deadline, measured > 0, Date() >= deadline { stopped = true; break }
                let item = self.rows[row]
                let old = self.heights[item.id]?.value
                let value = self.measure(item, width: width)
                self.heights[item.id] = Height(value: value, width: width, measured: true)
                self.queue.markMeasured(row)
                measured += 1
                if old.map({ abs($0 - value) > 0.5 }) ?? true { changed.insert(row) }
            }
            self.prefetchStats.rowsMeasured += measured
            return (changed, stopped)
        }

        /// Measures unmeasured rows from a screen above the viewport to a screen below it, so rows
        /// have their real height before they scroll into view. Returns the rows that changed.
        private func measureAroundViewport() -> IndexSet {
            let width = self.width
            guard width > 40, let window = self.window(screens: 1) else { return [] }
            self.syncQueueWidth(width)
            let start = Date()
            defer { self.prefetchStats.seconds += Date().timeIntervalSince(start) }
            return self.measure(self.queue.next(center: window.center, window: window.range, limit: .max),
                                width: width, deadline: nil).changed
        }

        /// The scroll callback's share: rows on screen and a little beyond, within a few
        /// milliseconds. Whatever doesn't fit waits for the next turn of the run loop.
        private func measureNearViewport() -> IndexSet {
            let width = self.width
            guard width > 40, !self.freeze.isFrozen, let window = self.window(screens: 0.5) else { return [] }
            self.syncQueueWidth(width)
            let start = Date()
            defer { self.prefetchStats.seconds += Date().timeIntervalSince(start) }
            // Rows on screen are always measured; only the margin is held to the budget.
            var changed = IndexSet()
            if let onScreen = self.window(screens: 0, minimum: 0) {
                let rows = self.queue.next(center: onScreen.center, window: onScreen.range, limit: .max)
                changed = self.measure(rows, width: width, deadline: nil).changed
            }
            let now = self.premeasure.plan(self.queue.next(center: window.center, window: window.range, limit: .max),
                                           all: self.rows, width: width, renderer: self.renderer, overflow: .measureNow) { [weak self] in
                self?.scheduleScrollMeasure()
            }
            let result = self.measure(now, width: width, deadline: start.addingTimeInterval(0.004))
            if result.stopped { self.scheduleScrollMeasure() }
            return changed.union(result.changed)
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
            guard let table else { return }
            let resized = self.measureNearViewport()
            guard !resized.isEmpty else { return }
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: resized) }
            self.restore(self.anchor)
        }

        /// A row's layout was rebuilt after being evicted from the renderer's cache. If a change
        /// (a reaction, say) made it a different height than measured, correct the table.
        private func relaidOut(_ id: String, width: CGFloat, height: CGFloat) {
            self.correctHeight(id, width: width, height: height)
        }

        /// If a row's fresh layout is a different height than the one stored, fixes the table on
        /// the next turn (this can run while the table is building cells).
        private func correctHeight(_ id: String, width: CGFloat, height: CGFloat) {
            guard width == self.width, let row = self.index[id], let old = self.heights[id], old.measured,
                  old.width == width, abs(old.value - height) > 0.5 else { return }
            self.heights[id] = Height(value: max(1, height), width: width, measured: true)
            self.pendingFixes.insert(row)
            guard !self.fixesScheduled else { return }
            self.fixesScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let table = self.table else { return }
                self.fixesScheduled = false
                let rows = self.pendingFixes.filteredIndexSet { $0 < self.rows.count }
                self.pendingFixes = []
                guard !rows.isEmpty else { return }
                self.isAdjusting = true
                defer { self.isAdjusting = false }
                self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: rows) }
                self.restore(self.anchor)
            }
        }

        /// Measures the rest of the transcript near the viewport in small slices while the reader
        /// isn't scrolling, nearest rows first, so heights are final before rows scroll into view.
        /// Correcting a height mid-scroll means moving the scroll position under the reader's
        /// fingers. Rows more than `screensAhead` screens away keep their estimates, and once the
        /// window is measured a step costs no more than finding the window.
        private func schedulePrefetch() {
            guard !self.prefetchScheduled else { return }
            self.prefetchScheduled = true
            DispatchQueue.main.async { [weak self] in self?.prefetchStep() }
        }

        func prefetchStep() {
            self.prefetchScheduled = false
            guard !self.isLiveScrolling, let table, !self.queue.isEmpty else { return }
            let width = self.width
            guard width > 40, !self.freeze.isFrozen, let window = self.window(screens: CGFloat(TranscriptMeasureQueue.screensAhead)) else { return }
            self.syncQueueWidth(width)
            let start = Date()
            defer {
                self.prefetchStats.steps += 1
                self.prefetchStats.seconds += Date().timeIntervalSince(start)
            }
            let deadline = start.addingTimeInterval(0.006)
            var changed = IndexSet()
            var remaining = false
            while true {
                let batch = self.queue.next(center: window.center, window: window.range, limit: 32 + self.premeasure.inFlightCount)
                if batch.isEmpty { break }
                // Rows still on the worker stay queued; its completion runs another step.
                let now = self.premeasure.plan(batch, all: self.rows, width: width, renderer: self.renderer, overflow: .wait) { [weak self] in
                    self?.schedulePrefetch()
                }
                if now.isEmpty { break }
                let result = self.measure(now, width: width, deadline: deadline)
                changed.formUnion(result.changed)
                if result.stopped || Date() >= deadline { remaining = true; break }
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
            self.isScrollingToBottom = false
        }

        @objc private func liveScrollEnded() {
            self.isLiveScrolling = false
            self.schedulePrefetch()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < self.rows.count else { return 1 }
            let item = self.rows[row]
            if let height = self.heights[item.id] { return height.value }
            let estimate = TranscriptLayout.estimatedHeight(item, width: self.width, hasReactions: { self.context.hasReactions($0) })
            self.heights[item.id] = Height(value: estimate, width: self.width, measured: false)
            return estimate
        }

        // MARK: Cells

        func numberOfRows(in tableView: NSTableView) -> Int { self.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = self.rows[row]
            let cell = tableView.makeView(withIdentifier: TranscriptCell.reuseIdentifier, owner: nil) as? TranscriptCell
                ?? TranscriptCell()
            let layout = self.renderer.layout(for: item, width: self.width)
            self.correctHeight(item.id, width: self.width, height: layout.height)
            cell.apply(layout, actions: self.renderer)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        // MARK: Scrolling

        @objc private func clipChanged() {
            guard let clip = self.scrollView?.contentView else { return }
            defer { self.reportPosition() }
            if clip.frame.size != self.clipSize {
                // Window resize, a panel sliding or the composer growing: keep the same message in
                // view. A width change freezes layout at the old width until it settles.
                let old = self.clipSize
                self.clipSize = clip.frame.size
                if old.width != clip.frame.width, old.width > 0 {
                    self.widthDidChange(from: old.width, to: clip.frame.width)
                }
                self.settle(changed: IndexSet())
                return
            }
            let offset = clip.bounds.minY
            defer { self.lastOffset = offset }
            guard !self.isAdjusting, !self.isScrollingToBottom else { return }
            // Mid-slide clip state must not become the anchor; only a real scroll moves it.
            if self.freeze.isFrozen, abs(offset - self.lastOffset) <= 0.5 { return }
            // Scrolling up leaves the bottom right away; only scrolling down re-sticks early.
            let movingUp = offset < self.lastOffset - 0.5
            self.anchor = self.currentAnchor(stickDistance: movingUp ? 1 : TranscriptLayout.stickToBottomDistance)
            self.applyNearViewport()
            self.pinVisibleImages()
            self.loadOlderIfShown()
        }

        private var olderRowWasVisible = false

        /// Pages older history in when the loading row comes into view (once per appearance; a
        /// prepend resets it, so a short transcript keeps loading).
        private func loadOlderIfShown() {
            let visible = self.isOlderRowVisible
            defer { self.olderRowWasVisible = visible }
            guard visible, !self.olderRowWasVisible else { return }
            self.renderer.loadOlderIfShown { [weak self] in self?.isOlderRowVisible ?? false }
        }

        private var isOlderRowVisible: Bool {
            guard case .loadingOlder? = self.rows.first, let table else { return false }
            let range = table.rows(in: table.visibleRect)
            return range.length > 0 && range.location == 0
        }

        private func pinVisibleImages() {
            guard let table, self.width > 40 else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            self.renderer.pinImages(of: self.rows[visible.location..<min(visible.location + visible.length, self.rows.count)],
                                    width: self.width)
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
        private func currentAnchor(stickDistance: CGFloat = TranscriptLayout.stickToBottomDistance,
                                   allowTop: Bool = true) -> Anchor {
            guard let table, let clip = self.scrollView?.contentView, !self.rows.isEmpty else { return .bottom }
            let bounds = clip.bounds
            let range = self.offsetRange()
            if range.upperBound - bounds.minY <= stickDistance { return .bottom }
            // The loading row is never the anchor: history prepended above it would move the reader.
            let loadingFirst: Bool = if case .loadingOlder = self.rows[0] { true } else { false }
            if allowTop, !loadingFirst, bounds.minY - range.lowerBound <= 1 { return .top }
            var row = table.row(at: NSPoint(x: 1, y: bounds.midY))
            if row < 0 { row = bounds.midY < 0 ? 0 : self.rows.count - 1 }
            if loadingFirst, row == 0, self.rows.count > 1 { row = 1 }
            return .row(self.rows[row].id, table.rect(ofRow: row).minY - bounds.minY)
        }

        private func restore(_ anchor: Anchor) {
            guard let table, let scroll = self.scrollView else { return }
            let range = self.offsetRange()
            let target: CGFloat
            switch anchor {
            case .bottom:
                target = range.upperBound
            case .top:
                target = range.lowerBound
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

        // MARK: Scroll to bottom

        private weak var scrollToBottomModel: ScrollToBottomModel?
        /// The scroll-to-bottom animation is running; its frames don't move the anchor.
        private var isScrollingToBottom = false
        private var scrollToBottomToken = 0

        func attach(_ model: ScrollToBottomModel?) {
            guard model !== self.scrollToBottomModel else { return }
            self.scrollToBottomModel = model
            model?.perform = { [weak self] in self?.scrollToBottom() }
        }

        private func reportPosition() {
            guard let model = self.scrollToBottomModel, let scroll = self.scrollView else { return }
            let clip = scroll.contentView
            let distance = self.rows.isEmpty ? 0 : self.offsetRange().upperBound - clip.bounds.minY
            model.report(distance: distance,
                         viewport: clip.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom,
                         lastRowId: self.rows.last?.id)
        }

        /// Scrolls to the latest message and follows it again. From far up it jumps to a screen
        /// above the end first, so the animation doesn't lay out the whole history on the way.
        func scrollToBottom() {
            guard let scroll = self.scrollView, !self.rows.isEmpty else { return }
            let clip = scroll.contentView
            self.anchor = .bottom
            let height = clip.bounds.height
            let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !animated || self.offsetRange().upperBound - clip.bounds.minY > height * 2 {
                self.isAdjusting = true
                let target = self.offsetRange().upperBound - (animated ? height : 0)
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
                scroll.reflectScrolledClipView(clip)
                self.isAdjusting = false
                if !animated {
                    self.settle(changed: IndexSet())
                    return
                }
            }
            self.scrollToBottomToken += 1
            let token = self.scrollToBottomToken
            self.isScrollingToBottom = true
            let target = NSPoint(x: clip.bounds.minX, y: self.offsetRange().upperBound)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.scrollToBottomEnded(token) }
            }
            // In case the animation never reports back (the window closed mid-scroll).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.scrollToBottomEnded(token) }
            }
        }

        private func scrollToBottomEnded(_ token: Int) {
            guard token == self.scrollToBottomToken, self.isScrollingToBottom, let scroll = self.scrollView else { return }
            self.isScrollingToBottom = false
            scroll.reflectScrolledClipView(scroll.contentView)
            // Rows measured on the way may have moved the end; land on it exactly.
            if self.anchor == .bottom { self.settle(changed: IndexSet()) }
            self.schedulePrefetch()
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
    private weak var actions: TranscriptRowActions?

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
        self.actions = actions
        self.content.apply(layout, actions: actions)
    }

    // One labelled group per message; its buttons and text stay reachable inside it.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { self.content.layout?.accessibilityLabel }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let layout = self.content.layout else { return nil }
        let actions = TranscriptRowAccessibilityAction.actions(for: layout, actions: self.actions, anchor: self.content)
        return actions.map { action in
            NSAccessibilityCustomAction(name: action.name) {
                action.perform()
                return true
            }
        }
    }
}

/// Reports the window it lands in so the coordinator can watch for the end of a live resize.
final class TranscriptScrollView: NSScrollView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.onWindowChange?(self.window)
    }
}
#endif
