import SwiftUI
import Testing
@testable import PincerUI
#if os(macOS)
import AppKit
#endif

/// #1088: the iPad chat header's model picker stays bounded and the Runs glyph sits centred like the
/// other toolbar icons, its badge drawn over it.
@Suite("Chat toolbar layout")
@MainActor
struct ChatToolbarLayoutTests {
    @Test func modelLabelIsBoundedAndTruncatesInTheMiddle() {
        #expect(ChatToolbarLayout.modelLabelMaxWidth > 0 && ChatToolbarLayout.modelLabelMaxWidth <= 240)
        #expect(ChatToolbarLayout.modelLabelTruncation == .middle)
    }

    @Test func runsIconCentresItsGlyphAndKeepsTheBadgeUnclipped() {
        #expect(RunsToolbarIcon.layout(isMac: false) == .centeredGlyph)
        #expect(RunsToolbarIcon.layout(isMac: true) == .bottomLeadingGlyph)
        #expect(RunsToolbarIcon.badgeAlignment == .topTrailing)
        // The bar clips an item to its frame: the badge may only reach into the item's ~5pt side padding.
        #expect(RunsToolbarIcon.badgeSide <= RunsToolbarIcon.side)
        #expect(RunsToolbarIcon.badgeOverhang >= 0 && RunsToolbarIcon.badgeOverhang < 5)
        #expect(RunsToolbarIcon.badgeText(running: 0) == nil)
        #expect(RunsToolbarIcon.badgeText(running: 1) == "1")
        #expect(RunsToolbarIcon.badgeText(running: 99) == "99")
        #expect(RunsToolbarIcon.badgeText(running: 100) == "99+")
    }

    #if os(macOS)
    private func size<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view.fixedSize())
        host.layout()
        return host.fittingSize
    }

    @Test func badgeTakesNoSpace() {
        let square = CGSize(width: RunsToolbarIcon.side, height: RunsToolbarIcon.side)
        #expect(self.size(RunsToolbarIcon(running: 0, layout: .centeredGlyph)) == square)
        #expect(self.size(RunsToolbarIcon(running: 42, layout: .centeredGlyph)) == square)
        #expect(self.size(RunsToolbarIcon(running: 120, layout: .centeredGlyph)) == square)
    }

    @Test func longModelNameLabelStaysBounded() {
        let short = self.size(ModelPickerLabel(title: "gpt-5"))
        let long = self.size(ModelPickerLabel(title: "claude-opus-5.5-extended-thinking-preview-2026-10-29"))
        #expect(short.width < long.width)
        #expect(long.width <= ChatToolbarLayout.modelLabelMaxWidth + 40)
    }
    #endif
}
