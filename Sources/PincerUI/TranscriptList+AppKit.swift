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
    /// Told how far the reader is from the latest message and whether the list follows the bottom;
    /// runs the scroll-to-bottom button's scroll (#439).
    var bottomState: TranscriptBottomState?
    /// Go ▸ Previous/Next Message for this list (#195).
    var navigator: TranscriptNavigator?

    func makeCoordinator() -> Coordinator { Coordinator(context: self.context) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.attach(self.bottomState)
        context.coordinator.update(rows: self.rows, context: self.context, insets: (self.topInset, self.bottomInset))
        context.coordinator.apply(self.highlight)
        context.coordinator.apply(self.jump)
        context.coordinator.install(self.navigator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, TranscriptListHost {
        /// Rows, heights, the anchor and measuring, shared with the UIKit list.
        let controller: TranscriptListController
        var renderer: TranscriptRenderer { self.controller.renderer }
        private var rows: [TranscriptRow] { self.controller.rows }
        private var anchor: TranscriptAnchor {
            get { self.controller.anchor }
            set { self.controller.anchor = newValue }
        }

        /// Whether the list is following the bottom (#335: the open chat may be trimmed then).
        var isAnchoredAtBottom: Bool { self.controller.isAnchoredAtBottom }
        /// Time spent measuring rows in idle slices and scroll callbacks, for the probe.
        var prefetchStats: (steps: Int, rowsMeasured: Int, seconds: Double) { self.controller.prefetchStats }
        /// Rows prepared on the worker, and text measured there; separate from `prefetchStats`.
        var premeasureStats: PremeasureStats { self.controller.premeasureStats }

        private var isAdjusting = false
        private var lastOffset: CGFloat = 0
        private var isLiveScrolling = false
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
        private weak var scrollView: NSScrollView?
        private weak var table: NSTableView?

        init(context: TranscriptContext) {
            self.controller = TranscriptListController(context: context, prefetchBudget: 0.006)
            super.init()
            self.controller.host = self
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
            table.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }
            table.onFocusChange = { [weak self] in self?.focusChanged() }
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
            table.setAccessibilityCustomRotors(self.makeRotors())
            return scroll
        }

        // MARK: Data

        func update(rows newRows: [TranscriptRow], context: TranscriptContext, insets: (top: CGFloat, bottom: CGFloat)) {
            let contextChanged = self.controller.beginUpdate(context: context, rowCount: newRows.count)
            defer {
                self.controller.revealPending()
                self.controller.loadOlderIfShown()
                self.reportPosition()
            }
            guard let table, let scroll = self.scrollView else { return }
            let top = TranscriptLayout.verticalInset + max(0, insets.top)
            let bottom = TranscriptLayout.verticalInset + max(0, insets.bottom)
            if abs(scroll.contentInsets.top - top) > 0.5 || abs(scroll.contentInsets.bottom - bottom) > 0.5 {
                scroll.contentInsets.top = top
                scroll.contentInsets.bottom = bottom
                if !self.rows.isEmpty, !contextChanged { self.settle(changed: IndexSet()) }
            }
            switch self.controller.accept(newRows, contextChanged: contextChanged) {
            case .unchanged:
                return
            case let .tail(row):
                self.settle(changed: IndexSet(integer: row))
            case .initial:
                table.reloadData()
                self.settle(changed: IndexSet())
            case let .rows(changed, oldIds):
                if let oldIds {
                    let diff = TranscriptListController.rowDiff(old: oldIds, new: self.rows.map(\.id))
                    self.withoutAnimation {
                        table.beginUpdates()
                        table.removeRows(at: diff.removals, withAnimation: [])
                        table.insertRows(at: diff.insertions, withAnimation: [])
                        table.endUpdates()
                    }
                }
                self.settle(changed: changed)
            }
        }

        /// Measures rows around the viewport, applies any height changes and puts the reader back
        /// where they were.
        func settle(changed: IndexSet) {
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
                if !self.freeze.isFrozen { resized.formUnion(self.controller.measureAroundViewport()) }
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
            self.refreshFocusRing()
            self.controller.schedulePrefetch()
        }

        /// Brings cells on screen up to date with their current layout. Cells skip layouts they
        /// already show, so this is cheap when nothing changed.
        private func refreshVisibleCells() {
            guard let table, let visible = self.visibleRows else { return }
            let width = self.layoutWidth
            guard width > TranscriptListController.minimumWidth else { return }
            for row in visible {
                let layout = self.renderer.layout(for: self.rows[row], width: width)
                self.controller.correctHeight(self.rows[row].id, width: width, height: layout.height)
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell else { continue }
                cell.apply(layout, actions: self.renderer)
            }
            self.renderer.pinImages(of: self.rows[visible], width: width)
        }

        func apply(_ jump: TranscriptJump?) {
            self.controller.apply(jump)
        }

        /// Highlights Find's matches and scrolls the selected one into view when asked to.
        func apply(_ highlight: TranscriptHighlight) {
            self.controller.apply(highlight)
        }

        /// Scrolls so the selected match (or the top of its row) sits a little above the middle
        /// of the visible area, clear of the chrome floating over the transcript.
        func reveal(_ id: String) {
            guard let table, let scroll = self.scrollView, let reveal = self.controller.prepareReveal(id) else { return }
            if reveal.moved {
                self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: [reveal.row]) }
            }
            let insets = scroll.contentInsets
            self.anchor = TranscriptListController.revealAnchor(
                id: id, insetTop: insets.top, visibleHeight: scroll.contentView.bounds.height - insets.top - insets.bottom,
                matchY: reveal.layout.matchY, rowHeight: reveal.layout.height)
            self.settle(changed: IndexSet())
        }

        /// Heights changed outside a settle (idle prefetch, the scroll callback, a correction):
        /// tell the table and put the reader back.
        func heightsChanged(_ rows: IndexSet) {
            guard let table else { return }
            let rows = rows.filteredIndexSet { $0 < self.rows.count }
            guard !rows.isEmpty else { return }
            self.isAdjusting = true
            defer { self.isAdjusting = false }
            self.withoutAnimation { table.noteHeightOfRows(withIndexesChanged: rows) }
            self.restore(self.anchor)
        }

        // MARK: Geometry

        /// The table's single column always spans the clip view.
        var layoutWidth: CGFloat {
            self.freeze.frozenWidth ?? self.scrollView?.contentView.bounds.width ?? 0
        }

        var isLayoutFrozen: Bool { self.freeze.isFrozen }

        var isScrolling: Bool { self.isLiveScrolling }

        var viewport: TranscriptViewport? {
            guard let clip = self.scrollView?.contentView, self.table != nil else { return nil }
            return TranscriptViewport(offset: clip.bounds.minY, height: clip.bounds.height, range: self.offsetRange())
        }

        func rowTop(_ row: Int) -> CGFloat? {
            guard let table, row < table.numberOfRows else { return nil }
            assert(table.numberOfRows == self.rows.count, "table out of step with rows")
            return table.rect(ofRow: row).minY
        }

        func row(atContentY y: CGFloat) -> Int? {
            guard let table, !self.rows.isEmpty else { return nil }
            let row = table.row(at: NSPoint(x: 1, y: y))
            if row >= 0 { return row }
            return y < 0 ? 0 : self.rows.count - 1
        }

        var visibleRows: ClosedRange<Int>? {
            guard let table else { return nil }
            let visible = table.rows(in: table.visibleRect)
            let end = min(visible.location + visible.length, self.rows.count)
            guard visible.length > 0, visible.location < end else { return nil }
            return visible.location...(end - 1)
        }

        /// The rows within `screens` viewport heights of the viewport, and the one in the middle.
        func rowWindow(screens: CGFloat, minimum: CGFloat) -> (range: ClosedRange<Int>, center: Int)? {
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

        // MARK: Width freeze

        /// Thaws right away, running the one relayout at the real width. For tests.
        func thawWidthNow() {
            self.thawItem?.cancel()
            self.thawItem = nil
            guard self.freeze.thaw() != nil else { return }
            if let state = self.frozenSignpost { TranscriptSignposts.end("WidthFrozen", state) }
            self.frozenSignpost = nil
            TranscriptSignposts.event("Thaw")
            self.controller.premeasure.cancelAll()
            if let clip = self.scrollView?.contentView { self.clipSize = clip.frame.size }
            self.controller.resetQueueWidth()
            self.controller.prewarmAroundViewport()
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
                self.controller.premeasure.cancelAll()
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

        // MARK: Prefetch

        func prefetchStep() {
            self.controller.prefetchStep()
        }

        @objc private func liveScrollStarted() {
            self.isLiveScrolling = true
            self.isScrollingToBottom = false
        }

        @objc private func liveScrollEnded() {
            self.isLiveScrolling = false
            self.controller.schedulePrefetch()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < self.rows.count else { return 1 }
            return self.controller.height(at: row, width: self.layoutWidth)
        }

        // MARK: Cells

        func numberOfRows(in tableView: NSTableView) -> Int { self.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = self.rows[row]
            let cell = tableView.makeView(withIdentifier: TranscriptCell.reuseIdentifier, owner: nil) as? TranscriptCell
                ?? TranscriptCell()
            let layout = self.renderer.layout(for: item, width: self.layoutWidth)
            self.controller.correctHeight(item.id, width: self.layoutWidth, height: layout.height)
            cell.apply(layout, actions: self.renderer)
            cell.showsFocusRing = self.showsFocusRing(at: row)
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
            self.controller.readerScrolled(movingUp: TranscriptListController.isMovingUp(from: self.lastOffset, to: offset))
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

        private func restore(_ anchor: TranscriptAnchor) {
            guard let scroll = self.scrollView, let target = self.controller.restoreTarget(anchor) else { return }
            let clip = scroll.contentView
            guard abs(clip.bounds.minY - target) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
            scroll.reflectScrolledClipView(clip)
        }

        // MARK: Message navigation (#195)

        private var rotorDelegates: [TranscriptRotorDelegate] = []

        func install(_ navigator: TranscriptNavigator?) {
            navigator?.move = { [weak self] forward in self?.navigate(forward: forward) }
        }

        /// Moves the current message, scrolls it into view, puts the focus ring on it and moves
        /// VoiceOver there.
        private func navigate(forward: Bool) {
            guard let table, let row = self.controller.moveNavigation(forward: forward) else { return }
            self.controller.scrollIntoView(row)
            if let window = table.window, window.firstResponder !== table { window.makeFirstResponder(table) }
            self.refreshFocusRing()
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TranscriptCell else { return }
            NSAccessibility.post(element: cell, notification: .focusedUIElementChanged)
        }

        private func showsFocusRing(at row: Int) -> Bool {
            guard let table, table.window?.firstResponder === table, self.rows.indices.contains(row) else { return false }
            return self.rows[row].id == self.controller.navigationRowId
        }

        fileprivate func refreshFocusRing() {
            guard let table, let visible = self.visibleRows else { return }
            for row in visible {
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell)?.showsFocusRing = self.showsFocusRing(at: row)
            }
        }

        /// The table took or lost the keyboard. Taking it starts on the current message, or the
        /// first one on screen.
        private func focusChanged() {
            if let table, table.window?.firstResponder === table {
                let known = self.controller.navigationRowId.flatMap { id in self.rows.firstIndex { $0.id == id } }
                if known.map({ self.visibleRows?.contains($0) ?? false }) != true {
                    self.controller.navigationRowId = nil
                    _ = self.controller.moveNavigation(forward: true)
                }
            }
            self.refreshFocusRing()
        }

        private func handleKey(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            switch event.keyCode {
            case 126: self.navigate(forward: false)
            case 125: self.navigate(forward: true)
            case 36, 76, 49: self.openActions()
            case 53: self.returnToComposer()
            default: return false
            }
            return true
        }

        /// Return and Space: the current message's actions menu, as a right-click would show.
        private func openActions() {
            guard let table, let id = self.controller.navigationRowId, let row = self.rows.firstIndex(where: { $0.id == id }),
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TranscriptCell else { return }
            cell.popUpActions()
        }

        private func returnToComposer() {
            guard let window = self.table?.window else { return }
            var ancestor = self.table?.superview
            while let view = ancestor {
                if let composer = Self.composer(in: view) {
                    window.makeFirstResponder(composer)
                    return
                }
                ancestor = view.superview
            }
            window.makeFirstResponder(nil)
        }

        private static func composer(in view: NSView) -> ComposerNSTextView? {
            for sub in view.subviews {
                if let composer = sub as? ComposerNSTextView { return composer }
                if let composer = self.composer(in: sub) { return composer }
            }
            return nil
        }

        // MARK: Rotors

        private func makeRotors() -> [NSAccessibilityCustomRotor] {
            let kinds: [(String, TranscriptNavKind)] = [
                (L("Messages"), .message), (L("Replies"), .reply), (L("Your Messages"), .user), (L("Tool Calls"), .tool),
            ]
            self.rotorDelegates = kinds.map { TranscriptRotorDelegate(kind: $0.1, coordinator: self) }
            return zip(kinds, self.rotorDelegates).map { kind, delegate in
                let rotor = NSAccessibilityCustomRotor(label: kind.0, itemSearchDelegate: delegate)
                rotor.itemLoadingDelegate = delegate
                return rotor
            }
        }

        /// The next or previous row of `kind` from the rotor's current item, searched in every row.
        /// VoiceOver enumerates the whole rotor, so a search never scrolls or builds cells: rows
        /// without a cell come back as a token, loaded only when VoiceOver moves to one.
        fileprivate func rotorResult(kind: TranscriptNavKind, from current: NSAccessibilityCustomRotor.ItemResult?,
                                     forward: Bool) -> NSAccessibilityCustomRotor.ItemResult? {
            guard let table else { return nil }
            var from: Int?
            if let cell = current?.targetElement as? NSView {
                let row = table.row(for: cell)
                if row >= 0 { from = row }
            } else if let id = current?.itemLoadingToken as? String {
                from = self.controller.index[id]
            }
            guard let row = self.controller.adjacentRow(from: from, forward: forward, kind: kind) else { return nil }
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptCell {
                let result = NSAccessibilityCustomRotor.ItemResult(targetElement: cell)
                result.customLabel = cell.spokenLabel ?? self.cheapLabel(self.rows[row])
                return result
            }
            return NSAccessibilityCustomRotor.ItemResult(itemLoadingToken: self.rows[row].id as NSString,
                                                         customLabel: self.cheapLabel(self.rows[row]))
        }

        /// Speaker and the start of the text, with no text layout (#431).
        private func cheapLabel(_ row: TranscriptRow) -> String {
            if let label = self.renderer.cachedLabel(for: row), !label.isEmpty { return label }
            guard case let .entry(entry) = row else { return "" }
            switch entry {
            case let .user(item):
                return [AccessibilityText.speaker(role: .user), AccessibilityText.summary(String(item.plainText.prefix(400)), limit: 80)]
                    .filter { !$0.isEmpty }.joined(separator: ", ")
            case let .assistant(turn):
                return [AccessibilityText.speaker(role: .assistant, author: self.controller.context.agent.name), AccessibilityText.summary(String((turn.text.first ?? "").prefix(400)), limit: 80)]
                    .filter { !$0.isEmpty }.joined(separator: ", ")
            case let .marker(_, label):
                return label
            }
        }

        /// Loads the row a token stands for: it becomes the current message, scrolled into view.
        fileprivate func rotorElement(forToken token: Any) -> NSAccessibilityElementProtocol? {
            guard let table, let id = token as? String, let row = self.controller.index[id] else { return nil }
            self.controller.navigationRowId = id
            self.controller.scrollIntoView(row)
            return table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TranscriptCell
        }

        // MARK: Scroll to bottom

        /// The scroll-to-bottom animation is running; its frames don't move the anchor.
        private(set) var isScrollingToBottom = false
        private var scrollToBottomToken = 0

        func attach(_ state: TranscriptBottomState?) {
            self.controller.attach(state) { [weak self] in self?.scrollToBottom() }
        }

        private func reportPosition() {
            guard let model = self.controller.bottom, let scroll = self.scrollView else { return }
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
            self.controller.schedulePrefetch()
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
    var onKeyDown: ((NSEvent) -> Bool)?
    var onFocusChange: (() -> Void)?

    /// Only Tab, Go ▸ Next/Previous Message and VoiceOver focus the list; a click must leave the
    /// keyboard with the composer.
    override var acceptsFirstResponder: Bool {
        guard let type = NSApp.currentEvent?.type else { return true }
        return ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { self.onFocusChange?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onFocusChange?() } }
        return accepted
    }

    /// VoiceOver's cursor follows the row the focus ring is on.
    override var accessibilityFocusedUIElement: Any? {
        (0..<self.numberOfRows).lazy
            .compactMap { self.view(atColumn: 0, row: $0, makeIfNecessary: false) as? TranscriptCell }
            .first { $0.showsFocusRing }
    }

    override func keyDown(with event: NSEvent) {
        if self.onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

private final class TranscriptCell: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("TranscriptCell")

    private let content = TranscriptRowView()
    private var serial: Int?
    private weak var actions: TranscriptRowActions?

    private let ring = TranscriptFocusRingView()

    init() {
        super.init(frame: .zero)
        self.identifier = Self.reuseIdentifier
        self.addSubview(self.content)
        self.ring.frame = self.bounds
        self.ring.autoresizingMask = [.width, .height]
        self.ring.isHidden = true
        self.addSubview(self.ring)
    }

    /// The keyboard focus ring around the row the arrow keys are on.
    var showsFocusRing: Bool {
        get { !self.ring.isHidden }
        set { if self.ring.isHidden == newValue { self.ring.isHidden = !newValue } }
    }

    override func isAccessibilityFocused() -> Bool { self.showsFocusRing }

    var spokenLabel: String? { self.content.layout?.accessibilityLabel }

    /// The row's actions menu at its first message, as a right-click there would open it.
    func popUpActions() {
        guard let window, let layout = self.content.layout else { return }
        let point = CGPoint(x: min(24, layout.width / 2), y: (layout.messages.first?.minY ?? 0) + 4)
        let windowPoint = self.content.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: windowPoint, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              let menu = self.content.menu(for: event) else { NSSound.beep(); return }
        menu.popUp(positioning: nil, at: point, in: self.content)
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

private final class TranscriptFocusRingView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        let path = NSBezierPath(roundedRect: self.bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8)
        path.lineWidth = 2
        path.stroke()
    }
}

/// Answers one rotor's searches for the table.
@MainActor
private final class TranscriptRotorDelegate: NSObject, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate, @preconcurrency NSAccessibilityElementLoading {
    let kind: TranscriptNavKind
    private weak var coordinator: TranscriptList.Coordinator?

    init(kind: TranscriptNavKind, coordinator: TranscriptList.Coordinator) {
        self.kind = kind
        self.coordinator = coordinator
    }

    func rotor(_ rotor: NSAccessibilityCustomRotor,
               resultFor parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
        self.coordinator?.rotorResult(kind: self.kind, from: parameters.currentItem,
                                      forward: parameters.searchDirection == .next)
    }

    func accessibilityElement(withToken token: NSAccessibilityLoadingToken) -> (any NSAccessibilityElementProtocol)? {
        self.coordinator?.rotorElement(forToken: token)
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
