import CoreGraphics
import Foundation
import Testing
@testable import PincerUI

@Suite("List controllers")
struct ListControllerTests {
    @Test func restoreTargetClampsToRange() {
        let range: ClosedRange<CGFloat> = -10...500
        #expect(TranscriptListController.restoreTarget(for: .bottom, rowTop: { _ in nil }, range: range) == 500)
        #expect(TranscriptListController.restoreTarget(for: .row("a", 20), rowTop: { _ in 120 }, range: range) == 100)
        #expect(TranscriptListController.restoreTarget(for: .row("a", 20), rowTop: { _ in 5000 }, range: range) == 500)
        #expect(TranscriptListController.restoreTarget(for: .row("a", 20), rowTop: { _ in -100 }, range: range) == -10)
        #expect(TranscriptListController.restoreTarget(for: .row("gone", 0), rowTop: { _ in nil }, range: range) == nil)
    }

    @Test func revealAnchorSitsAboveMiddle() {
        let anchor = TranscriptListController.revealAnchor(id: "r", insetTop: 50, visibleHeight: 500, matchY: 30, rowHeight: 100)
        #expect(anchor == .row("r", 50 + 200 - 30))
        let clamped = TranscriptListController.revealAnchor(id: "r", insetTop: 0, visibleHeight: 100, matchY: 900, rowHeight: 80)
        #expect(clamped == .row("r", 40 - 80))
        let none = TranscriptListController.revealAnchor(id: "r", insetTop: 0, visibleHeight: 100, matchY: nil, rowHeight: 80)
        #expect(none == .row("r", 40))
    }

    @Test func heightAndBottomThresholds() {
        #expect(TranscriptListController.heightMoved(from: nil, to: 10))
        #expect(!TranscriptListController.heightMoved(from: 10, to: 10.5))
        #expect(TranscriptListController.heightMoved(from: 10, to: 10.6))
        #expect(TranscriptListController.isAtBottom(maxOffset: 100, offset: 60, stickDistance: 40))
        #expect(!TranscriptListController.isAtBottom(maxOffset: 100, offset: 59, stickDistance: 40))
        let height = TranscriptRowHeight(value: 10, width: 300, measured: true)
        #expect(height.isCurrent(at: 300))
        #expect(!height.isCurrent(at: 301))
        #expect(!TranscriptRowHeight(value: 10, width: 300, measured: false).isCurrent(at: 300))
    }

    @Test func classifiesRowChanges() {
        let rows: [TranscriptRow] = [.loadingOlder]
        #expect(TranscriptListController.classify(old: rows, new: rows) == .streamingTail)
        #expect(TranscriptListController.classify(old: rows, new: []) == .other)
        #expect(TranscriptListController.classify(old: [], new: rows) == .other)
    }

    @Test func prefetchWalksOutwardFromCenter() {
        let rows = [TranscriptRow](repeating: .loadingOlder, count: 6)
        var order: [Int] = []
        let result = TranscriptListController.prefetchSlice(
            rows: rows, center: 2, budget: 10, isMeasured: { _ in false },
            measure: { row, _ in order.append(row); return row.isMultiple(of: 2) })
        #expect(order == [2, 1, 3, 0, 4, 5])
        #expect(!result.remaining)
        #expect(result.changed == IndexSet([0, 2, 4]))
    }

    @Test func prefetchSkipsMeasuredAndStopsAtBudget() {
        let rows = [TranscriptRow](repeating: .loadingOlder, count: 4)
        var order: [Int] = []
        let done = TranscriptListController.prefetchSlice(
            rows: rows, center: 0, budget: 10, isMeasured: { _ in true },
            measure: { row, _ in order.append(row); return true })
        #expect(order.isEmpty && done.changed.isEmpty && !done.remaining)
        let spent = TranscriptListController.prefetchSlice(
            rows: rows, center: 0, budget: -1, isMeasured: { _ in false },
            measure: { row, _ in order.append(row); return true })
        #expect(order.isEmpty && spent.remaining)
    }

    @MainActor
    @Test func sidebarSelectionTargetAndGuard() {
        #expect(SidebarController.selectionTarget(selectedKey: "k") == SidebarModel.entryId("k"))
        #expect(SidebarController.selectionTarget(selectedKey: "k", hidesSelection: true) == nil)
        #expect(SidebarController.selectionTarget(selectedKey: nil) == nil)
        let controller = SidebarController()
        #expect(!controller.isProgrammatic)
        controller.programmatic {
            #expect(controller.isProgrammatic)
            controller.programmatic { #expect(controller.isProgrammatic) }
            #expect(controller.isProgrammatic)
        }
        #expect(!controller.isProgrammatic)
    }
}
