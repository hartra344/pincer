#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerUI

@MainActor
@Suite("Shared view helpers")
struct SharedViewHelpersTests {
    private func layout<V: View>(_ view: V) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func refreshButtonHostsWithAndWithoutHelp() {
        let helped = RefreshButton(isDisabled: false) {}
        let plain = RefreshButton(isDisabled: true, showsHelp: false) {}
        #expect(helped.showsHelp && !plain.showsHelp && plain.isDisabled)
        #expect(self.layout(helped).width > 0 && self.layout(plain) == self.layout(helped))
    }

    @Test func refreshButtonRunsItsAction() async {
        var ran = false
        let button = RefreshButton(isDisabled: false) { ran = true }
        await button.action()
        #expect(ran)
    }

    @Test func inlineNavigationBarTitleIsANoOpOnMac() {
        let text = Text(verbatim: "Title")
        #expect(self.layout(text.inlineNavigationBarTitle()) == self.layout(text))
    }
}
#endif
