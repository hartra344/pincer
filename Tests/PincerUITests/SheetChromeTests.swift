#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerUI

@MainActor
@Suite("Sheet chrome")
struct SheetChromeTests {
    private func size<V: View>(_ view: V) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func toolbarItemsKeepTheirDefaultTitles() {
        #expect(SheetCancelToolbarItem {}.title == L("Cancel"))
        #expect(SheetDoneToolbarItem {}.title == L("Done"))
        #expect(SheetCancelToolbarItem(title: L("Close")) {}.title == L("Close"))
    }

    @Test func toolbarItemsRunTheirAction() {
        var cancelled = 0
        var done = 0
        SheetCancelToolbarItem { cancelled += 1 }.action()
        SheetDoneToolbarItem { done += 1 }.action()
        #expect(cancelled == 1 && done == 1)
    }

    @Test func toolbarItemsHostInANavigationStack() {
        let view = NavigationStack { Text(verbatim: "Body") }
            .toolbar { SheetCancelToolbarItem {}; SheetDoneToolbarItem {} }
        #expect(self.size(view).width > 0)
    }

    @Test func cardChromeMatchesTheInlineComposition() {
        let content = Text(verbatim: "Card").frame(width: 200, height: 40)
        let inline = content
            .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, Theme.Spacing.row)
            .padding(.top, Theme.Spacing.sm)
        let helped = content.chatCardChrome(cornerRadius: 18)
        #expect(self.size(helped) == self.size(inline))
        #expect(self.size(helped).width == 200 + 2 * Theme.Spacing.row)
        #expect(self.size(helped).height == 40 + Theme.Spacing.sm)
    }
}
#endif
