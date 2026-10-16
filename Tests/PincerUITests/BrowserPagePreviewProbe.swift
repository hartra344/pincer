import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

/// #976 perf probe: laying out a transcript of 200 assistant turns that each carry browser cards
/// reads only cached data, so it stays within a plain-row layout budget on the main thread.
@MainActor
@Suite("Browser page preview probe")
struct BrowserPagePreviewProbe {
    @Test func layingOutManyBrowserCardsStaysWithinBudget() {
        let rows = 200
        // Warm fonts and caches so the measurement is steady state.
        _ = BrowserPagePreviewLayoutTests.make(tools: [BrowserPagePreviewLayoutTests.tool("warm")])
        var cards = 0
        let start = ContinuousClock.now
        for index in 0..<rows {
            let tools = (0..<3).map {
                BrowserPagePreviewLayoutTests.tool("c\(index)-\($0)", tab: "t\($0)", url: "https://example.com/p/\(index)/\($0)")
            }
            let (layout, _) = BrowserPagePreviewLayoutTests.make(tools: tools)
            cards += BrowserPagePreviewLayoutTests.cards(layout).count
        }
        let elapsed = ContinuousClock.now - start
        #expect(cards == rows * 3)
        // Includes building a gateway per row; the cards themselves are a few array reads.
        #expect(elapsed < PerfBudget.limit(.seconds(4)), "200 rows with cards laid out in \(elapsed)")
    }
}
