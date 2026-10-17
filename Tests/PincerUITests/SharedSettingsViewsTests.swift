#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor
@Suite("Shared settings views")
struct SharedSettingsViewsTests {
    private func layout<V: View>(_ view: V) -> NSSize {
        let host = NSHostingView(rootView: view.frame(width: 420))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test func noticeToastHostsAndLaysOut() {
        let toast = SettingsNoticeToast(id: UUID(), text: "Already handled.", severity: .success,
                                        isCurrent: { true }, clear: {})
        let size = layout(toast)
        #expect(size.height > 0)
    }

    @Test func paletteItemLabelGrowsWithSubtitle() {
        let plain = layout(PaletteItemLabel(title: "New Chat", subtitle: nil))
        let withSubtitle = layout(PaletteItemLabel(title: "New Chat", subtitle: "Start a conversation"))
        #expect(withSubtitle.height > plain.height)
    }

    @Test func mainWindowHelperIsCallable() {
        let raise: (OpenWindowAction) -> Void = { MainWindow.bringToFront(openWindow: $0) }
        _ = raise
    }
}
#endif
