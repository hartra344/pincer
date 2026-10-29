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
    check(ChatToolbarLayout.separatesModelAndThinkingItems(isMac: false), "on iPad the model and thinking pickers are separate toolbar items")
    check(!ChatToolbarLayout.separatesModelAndThinkingItems(isMac: true), "the macOS toolbar keeps them in one stable item (#262)")
    check(RunsToolbarIcon.layout(isMac: false) == .centeredGlyphOverlayBadge, "on iPad the Runs glyph is centred with the badge as an overlay")
    check(RunsToolbarIcon.layout(isMac: true) == .reservedBadgeSquare, "the macOS Runs icon keeps its square")
    check(RunsToolbarIcon.badgeAlignment == .topTrailing && RunsToolbarIcon.badgeOffset.width > 0 && RunsToolbarIcon.badgeOffset.height < 0,
          "the badge sits past the glyph's top-trailing corner")
    check(RunsToolbarIcon.badgeText(running: 0) == nil && RunsToolbarIcon.badgeText(running: 7) == "7"
          && RunsToolbarIcon.badgeText(running: 100) == "99+", "badge text: none when idle, capped at 99+")
    #if os(macOS)
    func size<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view.fixedSize())
        host.layout()
        return host.fittingSize
    }
    let glyph = size(Image(systemName: RunsToolbarIcon.glyph))
    let idle = size(RunsToolbarIcon(running: 0, layout: .centeredGlyphOverlayBadge))
    let busy = size(RunsToolbarIcon(running: 12, layout: .centeredGlyphOverlayBadge))
    check(idle == glyph && busy == glyph, "the overlaid badge doesn't change the Runs icon's size (glyph \(glyph), idle \(idle), busy \(busy))")
    let short = size(ModelPickerLabel(title: "gpt-5"))
    let long = size(ModelPickerLabel(title: "claude-opus-5.5-extended-thinking-preview-2026-10-29"))
    check(short.width < long.width && long.width <= ChatToolbarLayout.modelLabelMaxWidth + 40,
          "a long model name's label stays bounded (short \(short.width)pt, long \(long.width)pt)")
    #endif
}
