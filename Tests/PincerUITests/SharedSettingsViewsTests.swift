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

    @Test func fullManagementNoticeHostsAndGrowsWithExtraContent() {
        let plain = layout(FullManagementNotice(title: "Needs Full Management", message: Text("Open Connection to turn it on."), action: {}))
        let extra = layout(FullManagementNotice(title: "Needs Full Management", message: Text("Open Connection to turn it on."), action: {}) {
            Text("Not granted yet.")
        })
        #expect(plain.height > 0 && extra.height > plain.height)
    }

    @Test func fullManagementUnavailableHosts() {
        let plain = layout(FullManagementUnavailable(title: "Needs Full Management", message: Text("Open Connection."), action: {}))
        let extra = layout(FullManagementUnavailable(title: "Needs Full Management", systemImage: "lock", message: Text("Open Connection."), action: {}) {
            Text("Not granted yet.")
        })
        #expect(plain.height > 0 && extra.height > 0)
    }

    @Test func notConnectedViewHosts() {
        #expect(layout(NotConnectedView(description: Text("Connect to the Gateway."))).height > 0)
    }

    @Test func loadErrorSectionHostsAndRetryStaysEnabledByDefault() {
        let enabled = layout(Form { LoadErrorSection(error: "Couldn't load.") {} })
        let disabled = layout(Form { LoadErrorSection(error: "Couldn't load.", canRetry: false) {} })
        #expect(enabled.height > 0 && disabled.height == enabled.height)
    }

    @Test func loadErrorRetryBlockHostsAndGrowsWithLongErrors() {
        let short = layout(LoadErrorRetryBlock(error: "Failed.") {})
        let long = layout(LoadErrorRetryBlock(error: String(repeating: "Something went wrong. ", count: 20)) {})
        #expect(short.height > 0 && long.height > short.height)
    }

    @Test func mainWindowHelperIsCallable() {
        let raise: (OpenWindowAction) -> Void = { MainWindow.bringToFront(openWindow: $0) }
        _ = raise
    }
}
#endif
