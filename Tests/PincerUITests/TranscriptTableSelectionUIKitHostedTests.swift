#if os(iOS)
import Testing
import UIKit
@testable import PincerKit
@testable import PincerUI

@MainActor
struct TranscriptTableSelectionUIKitHostedTests {
    private func makeGrid() -> TranscriptTableGridView {
        let table = TableTextFixture.table(TableTextFixture.grid)
        let grid = TranscriptTableGridView(frame: CGRect(origin: .zero, size: table.contentSize))
        grid.set(table, identity: "row")
        return grid
    }

    @Test func selectedRangeBridgesThroughUITextInput() throws {
        let grid = makeGrid()
        let model = grid.textModel
        grid.selectedRange = NSRange(location: model.range(row: 0, column: 0).location, length: model.string.length)
        let range = try #require(grid.selectedTextRange)
        #expect(grid.text(in: range) == "A1\tB1\tC1\nA2\tB2\tC2\nA3\tB3\tC3")
        #expect(!grid.selectionRects(for: range).isEmpty)
        #expect(grid.hasText)
    }

    @Test func selectingThroughTextInputUpdatesRange() throws {
        let grid = makeGrid()
        let start = try #require(grid.position(from: grid.beginningOfDocument, offset: 1))
        let end = try #require(grid.position(from: grid.beginningOfDocument, offset: 6))
        grid.selectedTextRange = grid.textRange(from: start, to: end)
        #expect(grid.selectedRange == NSRange(location: 1, length: 5))
        #expect(grid.selectedText == "1\tB1\t")
    }

    @Test func positionsClampAndCompare() throws {
        let grid = makeGrid()
        #expect(grid.position(from: grid.endOfDocument, offset: 1) == nil)
        #expect(grid.position(from: grid.beginningOfDocument, offset: -1) == nil)
        #expect(grid.offset(from: grid.beginningOfDocument, to: grid.endOfDocument) == grid.textModel.length)
        #expect(grid.compare(grid.beginningOfDocument, to: grid.endOfDocument) == .orderedAscending)
    }

    @Test func copyActionsFollowSelection() {
        let grid = makeGrid()
        #expect(grid.canBecomeFirstResponder)
        #expect(!grid.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        #expect(grid.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil))
        grid.selectAll(nil)
        #expect(grid.selectedRange.length == grid.textModel.length)
        #expect(grid.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
    }
}
#endif
