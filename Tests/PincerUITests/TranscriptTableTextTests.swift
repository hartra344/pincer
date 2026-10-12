import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Tables for the selection tests: plain strings laid out with the transcript's own padding rules.
@MainActor
enum TableTextFixture {
    static let padding = TranscriptTableMetrics.padding

    static func attributed(_ text: String, bold: Bool = false) -> NSAttributedString {
        let style = TranscriptStyle.shared
        return NSAttributedString(string: text, attributes: [
            .font: bold ? style.bodySemibold : style.body,
            .foregroundColor: TranscriptColors.label,
        ])
    }

    /// Row 0 is the header. Heights come from the same measuring the layout uses.
    static func table(_ rows: [[String]], columnWidth: CGFloat = 120, boldHeader: Bool = false) -> TranscriptPart.Table {
        let cells = rows.enumerated().map { rowIndex, row in
            row.map { attributed($0, bold: boldHeader && rowIndex == 0) }
        }
        let columns = rows.first?.count ?? 0
        let widths = Array(repeating: columnWidth, count: columns)
        let heights = cells.map { row in
            (row.map { TranscriptText.size($0, width: max(columnWidth - padding, 1)).height }.max() ?? 0)
                .clamped(atLeast: TranscriptStyle.lineHeight(TranscriptStyle.shared.body)) + 10
        }
        let plain = rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        return TranscriptPart.Table(cells: cells, columnWidths: widths, rowHeights: heights, plainText: plain)
    }

    static let grid = [["A1", "B1", "C1"], ["A2", "B2", "C2"], ["A3", "B3", "C3"]]

    /// Centre of a cell's text rect, in grid coordinates.
    static func center(_ model: TranscriptTableText, row: Int, column: Int) -> CGPoint {
        let rect = model.textRect(row: row, column: column)
        return CGPoint(x: rect.midX, y: rect.midY)
    }
}

private extension CGFloat {
    func clamped(atLeast minimum: CGFloat) -> CGFloat { Swift.max(self, minimum) }
}

@MainActor
@Suite("Transcript table text")
struct TranscriptTableTextTests {
    @Test func stringJoinsCellsWithTabsAndRowsWithNewlines() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        #expect(model.string as String == "A1\tB1\tC1\nA2\tB2\tC2\nA3\tB3\tC3")
        #expect(model.length == model.string.length)
    }

    @Test func stringUsesRenderedTextNotMarkdownSource() {
        let table = TableTextFixture.table([["Name", "Note"], ["bold", "plain"]], boldHeader: true)
        // The Markdown source carries markers; the selectable text must not.
        let source = TranscriptPart.Table(cells: table.cells, columnWidths: table.columnWidths, rowHeights: table.rowHeights,
                                          plainText: "**Name**\t**Note**\n**bold**\tplain")
        let model = TranscriptTableText(table: source)
        #expect(model.string as String == "Name\tNote\nbold\tplain")
        #expect(!(model.string as String).contains("*"))
    }

    @Test func separatorsInsideACellAreReplacedByAnEqualLengthSpace() {
        let table = TableTextFixture.table([["a\tb", "c\nd"], ["e", "f"]])
        let model = TranscriptTableText(table: table)
        #expect(model.string as String == "a b\tc d\ne\tf")
        #expect(model.string.length == "a\tb\tc\nd\ne\tf".utf16.count)
    }

    @Test func rangesAndCellLookupRoundTripIncludingSeparatorsAndEmptyCells() {
        let model = TranscriptTableText(table: TableTextFixture.table([["A1", "", "C1"], ["", "B2", ""]]))
        #expect(model.string as String == "A1\t\tC1\n\tB2\t")
        for row in 0..<2 {
            for column in 0..<3 {
                let range = model.range(row: row, column: column)
                let cell = model.cell(containing: range.location)
                #expect(cell.row == row && cell.column == column, "start of (\(row),\(column))")
                // The end offset sits on the separator after the cell and still belongs to it.
                let end = model.cell(containing: NSMaxRange(range))
                #expect(end.row == row && end.column == column, "end of (\(row),\(column))")
            }
        }
        #expect(model.range(row: 0, column: 1).length == 0)
        #expect(model.text(in: model.range(row: 1, column: 1)) == "B2")
        #expect(model.text(in: model.range(row: 0, column: 0)) == "A1")
    }

    @Test func textClampsOutOfBoundsRanges() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        #expect(model.text(in: NSRange(location: 0, length: 10_000)) == model.string as String)
        #expect(model.text(in: NSRange(location: model.length + 5, length: 3)) == "")
        #expect(model.text(in: NSRange(location: model.length - 2, length: 50)) == "C3")
        #expect(model.text(in: NSRange(location: 0, length: 0)) == "")
    }

    @Test func offsetAtPointInsideACellLandsInThatCell() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        for row in 0..<3 {
            for column in 0..<3 {
                let offset = model.offset(at: TableTextFixture.center(model, row: row, column: column))
                let range = model.range(row: row, column: column)
                #expect(offset >= range.location && offset <= NSMaxRange(range), "(\(row),\(column)) → \(offset)")
            }
        }
    }

    @Test func offsetAtTheLeftAndRightEdgesOfACellPicksItsEnds() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        let rect = model.textRect(row: 1, column: 1)
        let range = model.range(row: 1, column: 1)
        #expect(model.offset(at: CGPoint(x: rect.minX + 0.5, y: rect.midY)) == range.location)
        #expect(model.offset(at: CGPoint(x: rect.maxX - 0.5, y: rect.midY)) == NSMaxRange(range))
    }

    @Test func offsetAtPointInPaddingClampsToTheNearestCell() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        let rect = model.textRect(row: 1, column: 1)
        let range = model.range(row: 1, column: 1)
        // Left padding of B2 (between the column edge and the text) → B2's start, not A2.
        let leftPadding = CGPoint(x: rect.minX - 6, y: rect.midY)
        #expect(model.offset(at: leftPadding) == range.location)
        // Top padding above B2's text stays in B2's row.
        let topPadding = CGPoint(x: rect.midX, y: rect.minY - 3)
        let top = model.offset(at: topPadding)
        #expect(top >= range.location && top <= NSMaxRange(range))
    }

    @Test func offsetBeyondTheRightAndBottomEdgesClampsToTheEnds() {
        let table = TableTextFixture.table(TableTextFixture.grid)
        let model = TranscriptTableText(table: table)
        let size = table.contentSize
        #expect(model.offset(at: CGPoint(x: size.width + 500, y: size.height + 500)) == model.length)
        #expect(model.offset(at: CGPoint(x: -500, y: -500)) == 0)
        let firstRow = model.textRect(row: 0, column: 0)
        let rightOfFirstRow = model.offset(at: CGPoint(x: size.width + 500, y: firstRow.midY))
        #expect(rightOfFirstRow == NSMaxRange(model.range(row: 0, column: 2)))
        let belowFirstColumn = model.offset(at: CGPoint(x: firstRow.midX, y: size.height + 500))
        #expect(belowFirstColumn >= model.range(row: 2, column: 0).location)
        #expect(belowFirstColumn <= NSMaxRange(model.range(row: 2, column: 0)))
    }

    @Test func offsetInAHorizontallyWideTableStaysInTheRightCell() {
        let row = (0..<30).map { "c\($0)" }
        let model = TranscriptTableText(table: TableTextFixture.table([row, row], columnWidth: 140))
        for column in [0, 7, 15, 29] {
            let offset = model.offset(at: TableTextFixture.center(model, row: 1, column: column))
            let range = model.range(row: 1, column: column)
            #expect(offset >= range.location && offset <= NSMaxRange(range), "column \(column)")
            #expect(model.cell(containing: offset).column == column)
        }
        let far = model.textRect(row: 0, column: 29)
        #expect(far.minX > 29 * 140)
    }

    @Test func selectionRectsForASingleCellLieWithinItsTextRect() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        let range = model.range(row: 1, column: 1)
        let rects = model.selectionRects(for: range)
        #expect(!rects.isEmpty)
        let bounds = model.textRect(row: 1, column: 1).insetBy(dx: -1, dy: -1)
        for rect in rects {
            #expect(bounds.contains(rect), "\(rect) outside \(bounds)")
            #expect(rect.width > 0 && rect.height > 0)
        }
    }

    @Test func selectionRectsForAPartialCellAreNarrowerThanTheWholeCell() {
        let model = TranscriptTableText(table: TableTextFixture.table([["abcdefgh"], ["x"]]))
        let range = model.range(row: 0, column: 0)
        let whole = model.selectionRects(for: range).reduce(CGRect.null) { $0.union($1) }
        let half = model.selectionRects(for: NSRange(location: range.location, length: 4)).reduce(CGRect.null) { $0.union($1) }
        #expect(!half.isNull && half.width < whole.width)
    }

    @Test func selectionRectsForAMultiRowRangeTouchEveryCellInside() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        let range = NSRange(location: model.range(row: 0, column: 1).location, length: NSMaxRange(model.range(row: 2, column: 1)) - model.range(row: 0, column: 1).location)
        let rects = model.selectionRects(for: range)
        #expect(!rects.isEmpty)
        // Each touched cell contributes a rect inside its own text rect.
        var touched = Set<String>()
        for row in 0...2 {
            for column in 0...2 {
                let cell = model.textRect(row: row, column: column).insetBy(dx: -1, dy: -1)
                if rects.contains(where: { cell.contains($0) }) { touched.insert("\(row),\(column)") }
            }
        }
        #expect(touched.contains("0,1") && touched.contains("0,2") && touched.contains("1,0") && touched.contains("2,1"))
        #expect(!touched.contains("0,0") && !touched.contains("2,2"))
        // No rect strays outside the cells.
        let allCells = (0...2).flatMap { row in (0...2).map { model.textRect(row: row, column: $0).insetBy(dx: -1, dy: -1) } }
        for rect in rects { #expect(allCells.contains { $0.contains(rect) }, "\(rect)") }
    }

    @Test func emptyRangeHasNoSelectionRects() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        #expect(model.selectionRects(for: NSRange(location: 3, length: 0)).isEmpty)
    }

    @Test func caretRectIsThinAndInsideTheCell() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        let range = model.range(row: 1, column: 0)
        let caret = model.caretRect(at: range.location + 1)
        #expect(caret.width <= 3 && caret.height > 0)
        #expect(model.textRect(row: 1, column: 0).insetBy(dx: -2, dy: -2).contains(caret))
    }

    @Test func wordRangeNeverCrossesASeparator() {
        let model = TranscriptTableText(table: TableTextFixture.table([["alpha beta", "gamma"], ["delta", "eps ilon"]]))
        #expect(model.string as String == "alpha beta\tgamma\ndelta\teps ilon")
        let beta = model.range(row: 0, column: 0)
        #expect(model.text(in: model.wordRange(at: beta.location + 1)) == "alpha")
        #expect(model.text(in: model.wordRange(at: NSMaxRange(beta) - 1)) == "beta")
        let gamma = model.range(row: 0, column: 1)
        #expect(model.text(in: model.wordRange(at: gamma.location + 2)) == "gamma")
        for offset in 0...model.length {
            let word = model.wordRange(at: offset)
            let text = model.text(in: word)
            #expect(!text.contains("\t") && !text.contains("\n"), "offset \(offset) → \(text.debugDescription)")
        }
    }

    @Test func wordRangeOnAnEmptyCellIsEmpty() {
        let model = TranscriptTableText(table: TableTextFixture.table([["a", ""], ["b", "c"]]))
        let empty = model.range(row: 0, column: 1)
        #expect(model.wordRange(at: empty.location).length == 0)
    }

    @Test func rowRangeCoversTheWholeRowIncludingTabs() {
        let model = TranscriptTableText(table: TableTextFixture.table(TableTextFixture.grid))
        let middle = model.range(row: 1, column: 1).location
        #expect(model.text(in: model.rowRange(at: middle)) == "A2\tB2\tC2")
        #expect(model.text(in: model.rowRange(at: 0)) == "A1\tB1\tC1")
        #expect(model.text(in: model.rowRange(at: model.length)) == "A3\tB3\tC3")
    }

    @Test func selectionFromTheMiddleOfOneCellToTheMiddleOfAnotherCopiesTabsAndNewlines() {
        let model = TranscriptTableText(table: TableTextFixture.table([["Alpha1", "B1", "C1"], ["A2", "Beta2", "C2"]]))
        let start = model.range(row: 0, column: 0).location + 2
        let end = model.range(row: 1, column: 1).location + 2
        #expect(model.text(in: NSRange(location: start, length: end - start)) == "pha1\tB1\tC1\nA2\tBe")
        #expect(model.text(in: NSRange(location: 0, length: model.length)) == "Alpha1\tB1\tC1\nA2\tBeta2\tC2")
    }

    @Test func aWrappedCellHasMultipleSelectionRects() {
        let long = Array(repeating: "wrapping", count: 12).joined(separator: " ")
        let model = TranscriptTableText(table: TableTextFixture.table([["h"], [long]], columnWidth: 100))
        let rects = model.selectionRects(for: model.range(row: 1, column: 0))
        #expect(rects.count > 1)
        let cell = model.textRect(row: 1, column: 0).insetBy(dx: -1, dy: -1)
        #expect(rects.allSatisfy { cell.contains($0) })
    }

    @Test func markdownRenderedTableCopiesVisibleText() throws {
        let part = try TableTextFixture.renderedTable("| Name | Note |\n| --- | --- |\n| **bold** | `code` |\n| [link](https://example.com) | *em* |")
        let model = TranscriptTableText(table: part)
        #expect(model.string as String == "Name\tNote\nbold\tcode\nlink\tem")
    }
}

extension TableTextFixture {
    /// The table part the real renderer builds for `markdown`.
    static func renderedTable(_ markdown: String, width: CGFloat = 700) throws -> TranscriptPart.Table {
        let layout = try renderedLayout(markdown, width: width).layout
        for placed in layout.parts {
            if case let .table(table) = placed.part { return table }
        }
        throw TableFixtureError.noTable
    }

    static func renderedLayout(_ markdown: String, width: CGFloat = 700, id: String = "table-reply") throws -> (layout: TranscriptRowLayout, renderer: TranscriptRenderer, gateway: GatewayStore, scratch: ScratchDefaults) {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:table:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "table", name: "Table"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let renderer = TranscriptRenderer(context: context)
        var turn = AssistantTurn(id: id, timestamp: Date(timeIntervalSince1970: 1))
        turn.text = [markdown]
        let layout = renderer.layout(for: .entry(.assistant(turn)), width: width)
        return (layout, renderer, gateway, scratch)
    }

    enum TableFixtureError: Error { case noTable }
}

@MainActor
@Suite("Transcript table text perf", .serialized)
struct TranscriptTableTextPerfTests {
    @Test func aLargeTableBuildsHitTestsAndHighlightsWithinBudget() {
        let rows = (0..<200).map { row in (0..<6).map { "r\(row) c\($0) lorem ipsum" } }
        let table = TableTextFixture.table(rows, columnWidth: 140)
        let clock = ContinuousClock()
        var model: TranscriptTableText!
        var rectCount = 0
        let elapsed = clock.measure {
            model = TranscriptTableText(table: table)
            let size = table.contentSize
            for index in 0..<100 {
                let point = CGPoint(x: size.width * CGFloat(index % 10) / 10 + 5, y: size.height * CGFloat(index) / 100 + 3)
                _ = model.offset(at: point)
            }
            rectCount = model.selectionRects(for: NSRange(location: 0, length: model.length)).count
        }
        #expect(rectCount >= 1200)
        #expect(elapsed < PerfBudget.limit(.milliseconds(400)), "200x6 model + 100 hit tests + full highlight took \(elapsed)")
    }

    @Test func buildingTheModelTouchesOnlyTheCellsItIsAskedAbout() {
        let rows = (0..<200).map { row in (0..<6).map { "r\(row) c\($0)" } }
        let table = TableTextFixture.table(rows, columnWidth: 140)
        let clock = ContinuousClock()
        let model = TranscriptTableText(table: table)
        let single = clock.measure { _ = model.offset(at: CGPoint(x: 10, y: 10)) }
        #expect(single < PerfBudget.limit(.milliseconds(100)), "one hit test on a 200x6 table took \(single)")
    }

    #if os(macOS)
    @Test func configuringTheGridDoesNotBuildTheTextModel() throws {
        let rows = (0..<200).map { row in (0..<6).map { "r\(row) c\($0)" } }
        let table = TableTextFixture.table(rows, columnWidth: 140)
        let grid = TranscriptTableGridView()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            grid.set(table, identity: "big")
            grid.frame = CGRect(origin: .zero, size: table.contentSize)
        }
        #expect(elapsed < PerfBudget.limit(.milliseconds(20)), "configuring a 200x6 grid took \(elapsed)")
        #expect(grid.selectedRange.length == 0)
    }
    #endif
}
