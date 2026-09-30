import CoreGraphics
import Foundation
import PincerKit

/// Where the reader is anchored in the transcript.
enum TranscriptAnchor: Equatable {
    /// Following the latest message.
    case bottom
    /// At the very top, wherever the rows below end up.
    case top
    /// Row id, and how far its top sits below the top of the viewport.
    case row(String, CGFloat)
}

/// A row's height, the width it was found at, and whether it came from a real layout or is only
/// an estimate.
struct TranscriptRowHeight: Equatable {
    var value: CGFloat
    var width: CGFloat
    var measured: Bool

    func isCurrent(at width: CGFloat) -> Bool { self.measured && self.width == width }
}

/// The scroll position in content coordinates: the viewport's top, its height, and the offsets
/// scrolling can reach (from the top of the first row, less the top inset, to the end).
struct TranscriptViewport: Equatable {
    var offset: CGFloat
    var height: CGFloat
    var range: ClosedRange<CGFloat>
}

/// What the AppKit or UIKit list provides to `TranscriptListController`: its geometry and the
/// few operations that differ per platform (applying heights, scrolling, settling).
@MainActor
protocol TranscriptListHost: AnyObject {
    /// The width rows are laid out at (0 before the view has a size).
    var layoutWidth: CGFloat { get }
    /// Whether layout is holding a width while a panel slides (#347). Always false on iOS.
    var isLayoutFrozen: Bool { get }
    /// Whether the reader is scrolling, when idle prefetch waits.
    var isScrolling: Bool { get }
    /// The scroll position, or nil while there's no view.
    var viewport: TranscriptViewport? { get }
    /// The top of a row in content coordinates, or nil when the view doesn't know it yet.
    func rowTop(_ row: Int) -> CGFloat?
    /// The row at `y` in content coordinates, or the nearest one; nil when there are no rows.
    func row(atContentY y: CGFloat) -> Int?
    /// The rows on screen.
    var visibleRows: ClosedRange<Int>? { get }
    /// The rows within `screens` viewport heights (at least `minimum` points) of the viewport, and
    /// the one in the middle.
    func rowWindow(screens: CGFloat, minimum: CGFloat) -> (range: ClosedRange<Int>, center: Int)?
    /// Tells the view that these rows' heights changed, then puts the reader back at the anchor.
    func heightsChanged(_ rows: IndexSet)
    /// Measures around the viewport, applies it and puts the reader back at the anchor.
    func settle(changed: IndexSet)
    /// Scrolls so a row (Find's selected match, a jump target) is in view.
    func reveal(_ id: String)
}

/// Platform-free state and logic shared by the AppKit and UIKit transcript lists (#55, #283): the
/// rows and their id index, row heights and the measure queue, the reading anchor, idle prefetch
/// and scroll-time measuring, height corrections, reveal, jump and paging older history in. The
/// platform lists keep the views, cells, scrolling and animations, and describe their geometry
/// through `TranscriptListHost`.
@MainActor
final class TranscriptListController {
    let renderer: TranscriptRenderer
    /// Rows prepared on the worker, and text measured there (#302/#431).
    let premeasure = TranscriptPremeasureDriver()
    weak var host: TranscriptListHost?

    private(set) var context: TranscriptContext
    private(set) var rows: [TranscriptRow] = []
    private(set) var index: [String: Int] = [:]
    private(set) var heights: [String: TranscriptRowHeight] = [:]
    private(set) var queue = TranscriptMeasureQueue()
    private var queueWidth: CGFloat = 0

    var anchor = TranscriptAnchor.bottom {
        didSet {
            guard (oldValue == .bottom) != (self.anchor == .bottom), let bottom = self.bottom else { return }
            let atBottom = self.anchor == .bottom
            DispatchQueue.main.async { [weak bottom] in bottom?.anchorChanged(atBottom: atBottom) }
        }
    }

    /// The bottom-state hook (#439): told (on a later main-queue turn) whenever the list starts or
    /// stops following the bottom, fed the scroll position, and runs the scroll-to-bottom command.
    private(set) weak var bottom: TranscriptBottomState?

    /// Connects `state`, which then runs `scrollToBottom` for the button.
    func attach(_ state: TranscriptBottomState?, scrollToBottom: @escaping () -> Void) {
        guard state !== self.bottom else { return }
        self.bottom = state
        state?.perform = scrollToBottom
    }
    /// Whether the list is following the bottom (#335: the open chat may be trimmed then).
    var isAnchoredAtBottom: Bool { self.anchor == .bottom }

    /// Time spent measuring rows in idle slices and scroll callbacks, for the probe.
    var prefetchStats: (steps: Int, rowsMeasured: Int, seconds: Double) = (0, 0, 0)
    var premeasureStats: PremeasureStats { self.premeasure.stats }

    private var prefetchScheduled = false
    private var scrollMeasureScheduled = false
    private var pendingFixes = Set<String>()
    private var fixesScheduled = false
    private var pendingReveal: String?
    private var lastJump: UUID?
    private var olderRowWasVisible = false

    /// Idle prefetch's time per step.
    let prefetchBudget: TimeInterval
    /// The scroll callback's time for rows just beyond the screen.
    static let scrollMeasureBudget: TimeInterval = 0.004
    /// Rows at least this wide are laid out; narrower means the view isn't sized yet.
    static let minimumWidth: CGFloat = 40

    init(context: TranscriptContext, prefetchBudget: TimeInterval) {
        self.context = context
        self.prefetchBudget = prefetchBudget
        self.renderer = TranscriptRenderer(context: context)
        self.premeasure.currentWidth = { [weak self] in self?.host?.layoutWidth ?? 0 }
        self.renderer.onInvalidate = { [weak self] ids, keepInPlace in
            self?.invalidate(ids, keepInPlace: keepInPlace)
        }
        self.renderer.visibleRowIds = { [weak self] in self?.visibleRowIds() ?? [] }
        self.renderer.onRelayout = { [weak self] id, width, height in
            self?.correctHeight(id, width: width, height: height)
        }
        self.renderer.onReveal = { [weak self] id in
            guard let self else { return }
            // A row paged in from older history arrives with the next update.
            if self.index[id] != nil { self.host?.reveal(id) } else { self.pendingReveal = id }
        }
    }

    // MARK: Rows

    /// How a new row list relates to the current one.
    enum RowsUpdate: Equatable {
        /// Nothing to do.
        case unchanged
        /// Streaming: same ids, only this (last) row's content differs.
        case tail(Int)
        /// The first rows arrived; the list starts at the bottom.
        case initial
        /// Rows changed. `changed` are rows updated in place; `oldIds` is set when rows came,
        /// went or moved.
        case rows(changed: IndexSet, oldIds: [String]?)
    }

    /// Takes the latest context. Returns whether it's a different chat or configuration, which
    /// starts the list over.
    func beginUpdate(context: TranscriptContext, rowCount: Int) -> Bool {
        let changed = context.differs(from: self.context)
        self.context = context
        self.renderer.update(context: context)
        if rowCount != self.rows.count { self.olderRowWasVisible = false }
        return changed
    }

    /// Adopts `newRows` (duplicate ids after the first are dropped) and marks what needs
    /// measuring. The caller updates its view to match the returned change.
    func accept(_ newRows: [TranscriptRow], contextChanged: Bool) -> RowsUpdate {
        if contextChanged {
            self.premeasure.cancelAll()
            self.heights.removeAll()
            self.rows = []
        }
        if case .top = self.anchor, newRows.first?.id != self.rows.first?.id {
            // Rows arriving above: keep reading the same row instead of following the top.
            self.anchor = self.currentAnchor(allowTop: false)
        }
        // Streaming: same ids, only the last row differs. One pass, no diffing. The rows are
        // already unique, so the new ones are too.
        if let last = newRows.last, self.rows.count == newRows.count, self.rows.last?.id == last.id,
           self.rows.dropLast() == newRows.dropLast() {
            let row = self.rows.count - 1
            guard self.rows[row] != last else { return .unchanged }
            self.rows[row] = last
            self.heights[last.id]?.measured = false
            self.queue.markUnmeasured(row)
            return .tail(row)
        }
        let unique = Self.uniqued(newRows)
        guard unique != self.rows else { return .unchanged }
        let oldRows = self.rows
        self.rows = unique
        self.index = Dictionary(unique.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

        if oldRows.isEmpty {
            self.anchor = .bottom
            self.rebuildQueue()
            return .initial
        }

        // Rows whose content changed (a streaming reply, a tool finishing) are updated in place;
        // their old height stays as the estimate until they're measured again.
        let oldById = Dictionary(oldRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = IndexSet()
        for (row, item) in unique.enumerated() {
            guard let old = oldById[item.id], old != item else { continue }
            self.heights[item.id]?.measured = false
            changed.insert(row)
        }
        let oldIds = oldRows.map(\.id)
        let newIds = unique.map(\.id)
        let idsChanged = oldIds != newIds
        if idsChanged {
            // Sending jumps to the end, even from far up, and follows the reply from there.
            if unique.contains(where: { $0.isPendingSend && oldById[$0.id] == nil }) { self.anchor = .bottom }
            self.forgetHeights(from: oldIds, to: newIds)
        }
        self.rebuildQueue()
        return .rows(changed: changed, oldIds: idsChanged ? oldIds : nil)
    }

    /// The next or previous row of `kind` from `row`, or nil at the ends (#195). `from == nil`
    /// starts before the first row going forward and after the last going backward.
    static func adjacentRow(in rows: [TranscriptRow], from row: Int?, forward: Bool,
                            kind: TranscriptNavKind = .message) -> Int? {
        let start = row.map { forward ? $0 + 1 : $0 - 1 } ?? (forward ? 0 : rows.count - 1)
        var i = start
        while rows.indices.contains(i) {
            if kind.includes(rows[i]) { return i }
            i += forward ? 1 : -1
        }
        return nil
    }

    func adjacentRow(from row: Int?, forward: Bool, kind: TranscriptNavKind = .message) -> Int? {
        Self.adjacentRow(in: self.rows, from: row, forward: forward, kind: kind)
    }

    static func uniqued(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }
    }

    /// Trimmed back to the window (#335): forget the heights of the rows that left.
    private func forgetHeights(from oldIds: [String], to newIds: [String]) {
        guard oldIds.count > newIds.count else { return }
        if oldIds.suffix(newIds.count).elementsEqual(newIds) {
            for id in oldIds.prefix(oldIds.count - newIds.count) { self.heights.removeValue(forKey: id) }
        } else if oldIds.count > newIds.count + 256 {
            self.heights = self.heights.filter { self.index[$0.key] != nil }
        }
    }

    /// Row removals (original indexes) and insertions (final indexes) that turn `old` into `new`.
    /// History arriving above and trimming back to the window (#335) skip diffing thousands of rows.
    static func rowDiff(old: [String], new: [String]) -> (removals: IndexSet, insertions: IndexSet) {
        if new.count > old.count, new.suffix(old.count).elementsEqual(old) {
            return (IndexSet(), IndexSet(integersIn: 0..<(new.count - old.count)))
        }
        if old.count > new.count, old.suffix(new.count).elementsEqual(new) {
            return (IndexSet(integersIn: 0..<(old.count - new.count)), IndexSet())
        }
        var removals = IndexSet()
        var insertions = IndexSet()
        for change in new.difference(from: old) {
            switch change {
            case let .remove(offset, _, _): removals.insert(offset)
            case let .insert(offset, _, _): insertions.insert(offset)
            }
        }
        return (removals, insertions)
    }

    // MARK: Heights

    /// A row's stored height, or an estimate (which is stored) until it's measured.
    func height(at row: Int, width: CGFloat) -> CGFloat {
        let item = self.rows[row]
        if let height = self.heights[item.id] { return height.value }
        let estimate = TranscriptLayout.estimatedHeight(item, width: width, hasReactions: { self.context.hasReactions($0) })
        self.heights[item.id] = TranscriptRowHeight(value: estimate, width: width, measured: false)
        return estimate
    }

    func syncQueueWidth(_ width: CGFloat) {
        guard width != self.queueWidth else { return }
        self.queueWidth = width
        self.premeasure.cancelAll()
        self.queue.markAllUnmeasured(count: self.rows.count)
    }

    /// Forgets the width the queue was built for, so the next measure re-queues every row.
    func resetQueueWidth() {
        self.queueWidth = 0
    }

    /// Recomputes what needs measuring after rows came, went or changed.
    func rebuildQueue() {
        let width = self.host?.layoutWidth ?? 0
        self.queueWidth = width
        self.queue.rebuild(count: self.rows.count) { row in
            guard let height = self.heights[self.rows[row].id] else { return true }
            return !height.isCurrent(at: width)
        }
    }

    /// Lays out `rows` at `width`, stopping at `deadline` (after at least one) if there is one.
    /// Rows already measured at this width are skipped. Returns the rows whose height moved and
    /// whether it stopped early.
    func measure(_ rows: [Int], width: CGFloat, deadline: Date?) -> (changed: IndexSet, stopped: Bool) {
        var changed = IndexSet()
        var measured = 0
        var stopped = false
        for row in rows {
            let item = self.rows[row]
            if self.heights[item.id]?.isCurrent(at: width) == true {
                self.queue.markMeasured(row)
                continue
            }
            if let deadline, measured > 0, Date() >= deadline { stopped = true; break }
            let old = self.heights[item.id]?.value
            let value = max(1, self.renderer.layout(for: item, width: width).height)
            self.heights[item.id] = TranscriptRowHeight(value: value, width: width, measured: true)
            self.queue.markMeasured(row)
            measured += 1
            if Self.heightMoved(from: old, to: value) { changed.insert(row) }
        }
        self.prefetchStats.rowsMeasured += measured
        return (changed, stopped)
    }

    /// A height counts as changed when it's new or moved by more than half a point.
    static func heightMoved(from old: CGFloat?, to new: CGFloat) -> Bool {
        old.map { abs($0 - new) > 0.5 } ?? true
    }

    /// Measures unmeasured rows from a screen above the viewport to a screen below it, so rows
    /// have their real height before they scroll into view. Returns the rows that changed.
    func measureAroundViewport() -> IndexSet {
        guard let host else { return [] }
        let width = host.layoutWidth
        guard width > Self.minimumWidth, let window = host.rowWindow(screens: 1, minimum: 200) else { return [] }
        self.syncQueueWidth(width)
        let start = Date()
        defer { self.prefetchStats.seconds += Date().timeIntervalSince(start) }
        return self.measure(self.queue.next(center: window.center, window: window.range, limit: .max),
                            width: width, deadline: nil).changed
    }

    /// The scroll callback's share: rows on screen and a little beyond, within a few
    /// milliseconds. Whatever doesn't fit waits for the next turn of the run loop.
    func measureNearViewport() -> IndexSet {
        guard let host else { return [] }
        let width = host.layoutWidth
        guard width > Self.minimumWidth, !host.isLayoutFrozen,
              let window = host.rowWindow(screens: 0.5, minimum: 200) else { return [] }
        self.syncQueueWidth(width)
        let start = Date()
        defer { self.prefetchStats.seconds += Date().timeIntervalSince(start) }
        // Rows on screen are always measured; only the margin is held to the budget.
        var changed = IndexSet()
        if let onScreen = host.rowWindow(screens: 0, minimum: 0) {
            let rows = self.queue.next(center: onScreen.center, window: onScreen.range, limit: .max)
            changed = self.measure(rows, width: width, deadline: nil).changed
        }
        let now = self.premeasure.plan(self.queue.next(center: window.center, window: window.range, limit: .max),
                                       all: self.rows, width: width, renderer: self.renderer, overflow: .measureNow) { [weak self] in
            self?.scheduleScrollMeasure()
        }
        let result = self.measure(now, width: width, deadline: start.addingTimeInterval(Self.scrollMeasureBudget))
        if result.stopped { self.scheduleScrollMeasure() }
        return changed.union(result.changed)
    }

    func scheduleScrollMeasure() {
        guard !self.scrollMeasureScheduled else { return }
        self.scrollMeasureScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollMeasureScheduled = false
            self.applyNearViewport()
        }
    }

    func applyNearViewport() {
        let resized = self.measureNearViewport()
        guard !resized.isEmpty else { return }
        self.host?.heightsChanged(resized)
    }

    /// Measures the rest of the transcript near the viewport in small slices while the reader
    /// isn't scrolling, nearest rows first, so heights are final before rows scroll into view.
    /// Correcting a height mid-scroll means moving the scroll position under the reader's
    /// fingers. Rows more than `screensAhead` screens away keep their estimates, and once the
    /// window is measured a step costs no more than finding the window.
    func schedulePrefetch() {
        guard !self.prefetchScheduled else { return }
        self.prefetchScheduled = true
        DispatchQueue.main.async { [weak self] in self?.prefetchStep() }
    }

    func prefetchStep() {
        self.prefetchScheduled = false
        guard let host, !host.isScrolling, !self.queue.isEmpty else { return }
        let width = host.layoutWidth
        guard width > Self.minimumWidth, !host.isLayoutFrozen,
              let window = host.rowWindow(screens: CGFloat(TranscriptMeasureQueue.screensAhead), minimum: 200) else { return }
        self.syncQueueWidth(width)
        let start = Date()
        defer {
            self.prefetchStats.steps += 1
            self.prefetchStats.seconds += Date().timeIntervalSince(start)
        }
        let deadline = start.addingTimeInterval(self.prefetchBudget)
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
            let before = self.queue.count
            let result = self.measure(now, width: width, deadline: deadline)
            changed.formUnion(result.changed)
            if result.stopped || Date() >= deadline { remaining = true; break }
            if self.queue.count == before { break }
        }
        if !changed.isEmpty { host.heightsChanged(changed) }
        if remaining { self.schedulePrefetch() }
    }

    /// If a row's fresh layout is a different height than the one stored, fixes the view on the
    /// next turn (this can run while the view is building cells).
    func correctHeight(_ id: String, width: CGFloat, height: CGFloat) {
        guard let host, width == host.layoutWidth, self.index[id] != nil, let old = self.heights[id], old.measured,
              old.width == width, abs(old.value - height) > 0.5 else { return }
        self.heights[id] = TranscriptRowHeight(value: max(1, height), width: width, measured: true)
        self.pendingFixes.insert(id)
        guard !self.fixesScheduled else { return }
        self.fixesScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fixesScheduled = false
            let rows = IndexSet(self.pendingFixes.compactMap { self.index[$0] })
            self.pendingFixes = []
            guard !rows.isEmpty else { return }
            self.host?.heightsChanged(rows)
        }
    }

    /// Rows whose layout changed without the rows themselves changing: an image arrived, a card
    /// opened, a setting changed. `keepInPlace` is a row the reader just clicked or tapped, which
    /// stays where it is on screen while it grows or shrinks below that point.
    func invalidate(_ ids: Set<String>?, keepInPlace: String?) {
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
        guard !changed.isEmpty, let host else { return }
        if let keepInPlace, let row = self.index[keepInPlace], let viewport = host.viewport, let top = host.rowTop(row) {
            self.anchor = .row(keepInPlace, top - viewport.offset)
            host.settle(changed: changed)
            self.anchor = self.currentAnchor()
        } else {
            host.settle(changed: changed)
        }
    }

    // MARK: Anchor

    /// The row at the middle of the viewport, or the bottom when the reader is at the end. The
    /// middle row is used because rows entering at the edges may still change height.
    func currentAnchor(stickDistance: CGFloat = TranscriptLayout.stickToBottomDistance,
                       allowTop: Bool = true) -> TranscriptAnchor {
        guard let host, let viewport = host.viewport, !self.rows.isEmpty else { return .bottom }
        return Self.anchor(in: viewport, rows: self.rows, stickDistance: stickDistance, allowTop: allowTop,
                           rowAt: host.row(atContentY:), rowTop: host.rowTop)
    }

    static func anchor(in viewport: TranscriptViewport, rows: [TranscriptRow], stickDistance: CGFloat, allowTop: Bool,
                       rowAt: (CGFloat) -> Int?, rowTop: (Int) -> CGFloat?) -> TranscriptAnchor {
        guard !rows.isEmpty else { return .bottom }
        if viewport.range.upperBound - viewport.offset <= stickDistance { return .bottom }
        // The loading row is never the anchor: history prepended above it would move the reader.
        let loadingFirst: Bool = if case .loadingOlder = rows[0] { true } else { false }
        if allowTop, !loadingFirst, viewport.offset - viewport.range.lowerBound <= 1 { return .top }
        guard var row = rowAt(viewport.offset + viewport.height / 2) else { return .bottom }
        row = min(max(row, 0), rows.count - 1)
        if loadingFirst, row == 0, rows.count > 1 { row = 1 }
        guard let top = rowTop(row) else { return .bottom }
        return .row(rows[row].id, top - viewport.offset)
    }

    /// The scroll offset that puts `anchor` back where it was, or nil when there's no view. A row
    /// that's gone re-anchors on whatever is in the middle of the viewport now.
    func restoreTarget(_ anchor: TranscriptAnchor) -> CGFloat? {
        guard let host, let viewport = host.viewport else { return nil }
        let row: Int? = if case let .row(id, _) = anchor { self.index[id] } else { nil }
        let target = Self.restoreTarget(for: anchor, range: viewport.range, rowTop: row.flatMap(host.rowTop))
        if target == nil { self.anchor = self.currentAnchor() }
        return target
    }

    static func restoreTarget(for anchor: TranscriptAnchor, range: ClosedRange<CGFloat>, rowTop: CGFloat?) -> CGFloat? {
        switch anchor {
        case .bottom:
            return range.upperBound
        case .top:
            return range.lowerBound
        case let .row(_, offset):
            guard let rowTop else { return nil }
            return min(max(rowTop - offset, range.lowerBound), range.upperBound)
        }
    }

    /// The reader scrolled. Scrolling up leaves the bottom right away; only scrolling down
    /// re-sticks early.
    func readerScrolled(movingUp: Bool) {
        self.anchor = self.currentAnchor(stickDistance: movingUp ? 1 : TranscriptLayout.stickToBottomDistance)
        self.applyNearViewport()
        self.pinVisibleImages()
        self.loadOlderIfShown()
    }

    static func isMovingUp(from lastOffset: CGFloat, to offset: CGFloat) -> Bool {
        offset < lastOffset - 0.5
    }

    // MARK: Reveal, jump and highlight

    /// Lays out a row to reveal at the current width, and stores its height. Returns its index,
    /// its layout and whether its height moved, or nil when it isn't in the list or there's no
    /// width yet.
    func prepareReveal(_ id: String) -> (row: Int, layout: TranscriptRowLayout, moved: Bool)? {
        guard let host, let row = self.index[id] else { return nil }
        let width = host.layoutWidth
        guard width > Self.minimumWidth else { return nil }
        let layout = self.renderer.layout(for: self.rows[row], width: width)
        let old = self.heights[id]?.value
        self.heights[id] = TranscriptRowHeight(value: max(1, layout.height), width: width, measured: true)
        self.syncQueueWidth(width)
        self.queue.markMeasured(row)
        return (row, layout, Self.heightMoved(from: old, to: layout.height))
    }

    /// The anchor that shows a row's match (or its top) a little above the middle of the visible
    /// area, clear of the chrome floating over the transcript.
    static func revealAnchor(id: String, insetTop: CGFloat, visibleHeight: CGFloat,
                             matchY: CGFloat?, rowHeight: CGFloat) -> TranscriptAnchor {
        let y = min(matchY ?? 0, rowHeight)
        return .row(id, insetTop + max(visibleHeight, 1) * 0.4 - y)
    }

    func revealPending() {
        guard let id = self.pendingReveal, self.index[id] != nil else { return }
        self.pendingReveal = nil
        self.host?.reveal(id)
    }

    func apply(_ jump: TranscriptJump?) {
        guard let jump, jump.id != self.lastJump else { return }
        self.lastJump = jump.id
        self.renderer.showOriginal(jump.messageId, missingNotice: PincerRoute.Notice.unknownMessage)
    }

    /// Highlights Find's matches and scrolls the selected one into view when asked to.
    func apply(_ highlight: TranscriptHighlight) {
        if highlight != self.renderer.highlight { self.premeasure.cancelAll() }
        guard let id = self.renderer.update(highlight: highlight) else { return }
        self.host?.reveal(id)
    }

    // MARK: Message navigation (#195)

    /// The message keyboard and VoiceOver navigation is on, by id so it survives rows shifting.
    var navigationRowId: String?

    /// The row `forward` from the current message, or from the edge of the screen when there's
    /// none (or it has left the list). The current message moves to it.
    func moveNavigation(forward: Bool, kind: TranscriptNavKind = .message) -> Int? {
        let current = self.navigationRowId.flatMap { self.index[$0] }
        var from = current
        if from == nil, let visible = self.visibleRange {
            from = forward ? visible.lowerBound - 1 : visible.upperBound + 1
        }
        // At either end the current message stays.
        guard let target = self.adjacentRow(from: from, forward: forward, kind: kind) ?? current else { return nil }
        self.navigationRowId = self.rows[target].id
        return target
    }

    /// Scrolls so the top of `row` is on screen, leaving the list where it is when it already is.
    func scrollIntoView(_ row: Int) {
        guard let host, self.rows.indices.contains(row) else { return }
        if let viewport = host.viewport, let top = host.rowTop(row) {
            let bottom = top + self.height(at: row, width: host.layoutWidth)
            let shown = min(bottom, top + viewport.height * 0.5)
            if top >= viewport.offset, shown <= viewport.offset + viewport.height { return }
        }
        host.reveal(self.rows[row].id)
    }

    // MARK: Visible rows

    func visibleRowIds() -> Set<String> {
        guard let visible = self.visibleRange else { return [] }
        return Set(self.rows[visible].map(\.id))
    }

    func pinVisibleImages() {
        guard let host, host.layoutWidth > Self.minimumWidth, let visible = self.visibleRange else { return }
        self.renderer.pinImages(of: self.rows[visible], width: host.layoutWidth)
    }

    private var visibleRange: ClosedRange<Int>? {
        guard let visible = self.host?.visibleRows, !self.rows.isEmpty, visible.lowerBound < self.rows.count else { return nil }
        return max(visible.lowerBound, 0)...min(visible.upperBound, self.rows.count - 1)
    }

    /// Pages older history in when the loading row comes into view (once per appearance; a
    /// prepend resets it, so a short transcript keeps loading).
    func loadOlderIfShown() {
        let visible = self.isOlderRowVisible
        defer { self.olderRowWasVisible = visible }
        guard visible, !self.olderRowWasVisible else { return }
        self.renderer.loadOlderIfShown { [weak self] in self?.isOlderRowVisible ?? false }
    }

    private var isOlderRowVisible: Bool {
        guard case .loadingOlder? = self.rows.first, let visible = self.host?.visibleRows else { return false }
        return visible.lowerBound == 0
    }
}

/// Which rows keyboard and rotor navigation stops on (#195).
enum TranscriptNavKind {
    case message, reply, user, tool

    func includes(_ row: TranscriptRow) -> Bool {
        guard case let .entry(entry) = row else { return false }
        switch (self, entry) {
        case (_, .marker): return false
        case (.message, _): return true
        case (.reply, .assistant): return true
        case (.user, .user): return true
        case let (.tool, .assistant(turn)): return !turn.tools.isEmpty
        default: return false
        }
    }
}

/// Lets Go ▸ Previous/Next Message reach the focused pane's list (#195). The list installs `move`.
@MainActor
final class TranscriptNavigator {
    var move: ((_ forward: Bool) -> Void)?
}
