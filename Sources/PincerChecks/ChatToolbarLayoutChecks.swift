#if os(macOS)
import AppKit
#endif
import SwiftUI
@testable import PincerUI

/// #1088: the iPad chat header's trailing controls keep standard, symmetric spacing.
@MainActor
func runChatToolbarLayoutChecks() {
    check(ChatToolbarLayout.modelLabelMaxWidth > 0 && ChatToolbarLayout.modelLabelMaxWidth <= 240,
          "the model picker's title has a bounded width (\(ChatToolbarLayout.modelLabelMaxWidth)pt)")
    check(ChatToolbarLayout.modelLabelTruncation == .middle, "a long model name truncates in the middle")
    check(RunsToolbarIcon.layout(isMac: false) == .centeredGlyph, "on iPad the Runs glyph is centred in its square")
    check(RunsToolbarIcon.layout(isMac: true) == .bottomLeadingGlyph, "the macOS Runs icon keeps its bottom-leading glyph")
    check(RunsToolbarIcon.badgeAlignment == .topTrailing && RunsToolbarIcon.badgeSide <= RunsToolbarIcon.side
          && RunsToolbarIcon.badgeOverhang >= 0 && RunsToolbarIcon.badgeOverhang < 5,
          "the badge stays inside the square's height and within the bar item's padding, so it isn't clipped")
    check(RunsToolbarIcon.badgeText(running: 0) == nil && RunsToolbarIcon.badgeText(running: 7) == "7"
          && RunsToolbarIcon.badgeText(running: 100) == "99+", "badge text: none when idle, capped at 99+")
    #if os(macOS)
    func size<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view.fixedSize())
        host.layout()
        return host.fittingSize
    }
    let square = CGSize(width: RunsToolbarIcon.side, height: RunsToolbarIcon.side)
    let idle = size(RunsToolbarIcon(running: 0, layout: .centeredGlyph))
    let busy = size(RunsToolbarIcon(running: 120, layout: .centeredGlyph))
    check(idle == square && busy == square, "the badge doesn't change the Runs icon's size (idle \(idle), busy \(busy))")
    let short = size(ModelPickerLabel(title: "gpt-5"))
    let long = size(ModelPickerLabel(title: "claude-opus-5.5-extended-thinking-preview-2026-10-29"))
    check(short.width < long.width && long.width <= ChatToolbarLayout.modelLabelMaxWidth + 40,
          "a long model name's label stays bounded (short \(short.width)pt, long \(long.width)pt)")
    #endif
}
