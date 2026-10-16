import Foundation
import PincerKit
import SwiftUI
#if DEBUG && os(macOS)
@testable import PincerUI

// #976 × #974: tapping a browser page card opens the browser panel on that tab when the panel can
// stream it, and otherwise leaves the tap to the card, which opens the URL externally.
@MainActor
func checkBrowserCardRouting(_ gateway: GatewayStore, page: BrowserPagePreview, label: String) {
    var showWorkspace = false
    let actions = ChatChromeActions(showRuns: .constant(false),
                                    showWorkspace: Binding(get: { showWorkspace }, set: { showWorkspace = $0 }),
                                    toolsInspector: .constant(nil))
    let canShow = gateway.advertises("browser.request") && gateway.browserPanel.hasAdmin
    check(canShow, "\(label): the browser panel can show pages (browser.request advertised, admin)")
    let handled = actions.openBrowserPage(page, in: gateway)
    check(handled && showWorkspace, "\(label): a card tap opens the browser panel")
    check(gateway.browserPanel.selectedTargetId == page.tab.targetId,
          "\(label): the panel selects the card's tab (\(gateway.browserPanel.selectedTargetId ?? "nil"))")
    gateway.browserPanel.stop()
}
#endif
