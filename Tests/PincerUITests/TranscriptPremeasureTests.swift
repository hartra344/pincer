import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

@MainActor
@Suite("TranscriptPremeasure", .serialized)
struct TranscriptPremeasureTests {
    static let sources = [
        "Plain paragraph with **bold**, _italic_ and `code` that wraps across a few lines when the column is narrow enough to force it.",
        "# Heading\n\n- one\n- two with a longer item that should wrap at small widths\n  - nested\n\n1. first\n2. second",
        "> A quote that is long enough to wrap when the width is small, and keeps wrapping past that.\n\n```swift\nlet x = 1\n```\n\n---\n\nafter",
    ]

    private func premeasure(_ source: String, tone: TranscriptText.Tone, width: CGFloat) async -> PremeasuredRow {
        let key = PremeasureKey(source: source, tone: tone, styleGeneration: TranscriptStyle.generation, dark: false)
        let job = PremeasureJob(rowId: "r", bodies: [key], contentWidth: width, epoch: 0)
        let env = TextBuildEnvironment.current(dark: false)
        return await withCheckedContinuation { continuation in
            TranscriptPremeasurer.shared.submit([job], env: env, epoch: TranscriptPremeasureEpoch()) { rows in
                continuation.resume(returning: rows[0])
            }
        }
    }

    @Test func workerSizesMatchMainSizes() async {
        for source in Self.sources {
            for width in [320, 480, 700, 1100] as [CGFloat] {
                let row = await premeasure(source, tone: .primary, width: width)
                let body = try! #require(row.bodies.first)
                let main = TranscriptText.markdown(source, tone: .primary, dark: false)
                #expect(body.segments.count == main.count)
                for height in body.heights {
                    let text: NSAttributedString
                    switch main[height.index] {
                    case let .text(string), let .quote(string), let .code(_, _, string): text = string
                    default: continue
                    }
                    let size = TranscriptText.size(text, width: height.width, exact: height.exact)
                    #expect(size.height == height.height && size.width == height.usedWidth)
                }
            }
        }
    }

    @Test func adoptingResultsMakesTheTextWarm() async {
        let source = "Warm me **up**, then measure me again without TextKit. " + String(repeating: "word ", count: 80)
        let key = PremeasureKey(source: source, tone: .primary, styleGeneration: TranscriptStyle.generation, dark: false)
        let width: CGFloat = 640
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: width)
        #expect(!TranscriptText.isWarm(key.textKey, contentWidth: contentWidth))
        let driver = TranscriptPremeasureDriver()
        let row = await premeasure(source, tone: .primary, width: contentWidth)
        #expect(driver.adopt([row], width: width, epoch: driver.epoch.current) == ["r"])
        #expect(TranscriptText.isWarm(key.textKey, contentWidth: contentWidth))
        let before = TranscriptText.measureStats
        for segment in TranscriptText.markdown(source, tone: .primary, dark: false) {
            if case let .text(text) = segment { _ = TranscriptText.size(text, width: contentWidth, memoized: true) }
        }
        #expect(TranscriptText.measureStats.mainLayouts == before.mainLayouts)
        #expect(TranscriptText.measureStats.memoHits > before.memoHits)
        #expect(TranscriptPremeasurer.offMainLayouts.withLock { $0 } > 0)
    }

    @Test func tableCellsMatchMainAndWarmTheRow() async {
        let source = "| Name | Notes |\n|---|---:|\n| alpha | a fairly long note that has to wrap in a narrow column, more than once |\n| beta | short |"
        let width: CGFloat = 640
        let contentWidth = TranscriptMetrics.contentWidth(rowWidth: width)
        let row = await premeasure(source, tone: .primary, width: contentWidth)
        let body = try! #require(row.bodies.first)
        #expect(!body.cells.isEmpty)
        let driver = TranscriptPremeasureDriver()
        #expect(driver.adopt([row], width: width, epoch: driver.epoch.current) == ["r"])
        let key = body.key.textKey
        #expect(TranscriptText.isWarm(key, contentWidth: contentWidth))
        let main = TranscriptText.markdown(source, tone: .primary, dark: false)
        guard case let .table(table) = main.first(where: { if case .table = $0 { true } else { false } })! else { return }
        let before = TranscriptText.measureStats.mainLayouts
        var naturals = Array(repeating: CGFloat(0), count: table.cells[0].count)
        for cells in table.cells { for (column, cell) in cells.enumerated() { naturals[column] = max(naturals[column], TranscriptText.naturalWidth(cell, memoized: true)) } }
        let widths = TranscriptTableMetrics.columnWidths(naturals: naturals, available: contentWidth)
        for cells in table.cells {
            for (column, cell) in cells.enumerated() {
                _ = TranscriptText.size(cell, width: max(widths[column] - TranscriptTableMetrics.padding, 1), memoized: true)
            }
        }
        #expect(TranscriptText.measureStats.mainLayouts == before)
        for cell in body.cells {
            let text = table.cells[cell.row][cell.column]
            #expect(TranscriptText.size(text, width: cell.width).height == cell.height)
            #expect(TranscriptText.naturalWidth(text) == cell.natural)
        }
    }

    @Test func resultsFromAnOlderEpochOrWidthAreDropped() async {
        let driver = TranscriptPremeasureDriver()
        let row = await premeasure("Stale **result**", tone: .primary, width: TranscriptMetrics.contentWidth(rowWidth: 640))
        let old = driver.epoch.current
        driver.cancelAll()
        #expect(driver.adopt([row], width: 640, epoch: old).isEmpty)
        #expect(driver.adopt([row], width: 500, epoch: driver.epoch.current).isEmpty)
        #expect(driver.stats.discardedStale == 2 && driver.stats.adopted == 0)
    }

    @Test func darkAppearanceKeysTheSegmentCache() {
        let source = "Cost is $\\pi r^2$ here"
        let light = TranscriptText.markdown(source, tone: .primary, dark: false)
        let dark = TranscriptText.markdown(source, tone: .primary, dark: true)
        guard case let .text(a) = light[0], case let .text(b) = dark[0] else { Issue.record("expected text"); return }
        #expect(a !== b)
    }
}
