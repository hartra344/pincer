#if canImport(UIKit)
import PincerKit
import SwiftUI
import Testing
import UIKit
@testable import PincerUI

@MainActor
struct MCPStatusDetailDensityHostedTests {
    @Test func detailRetainsWrappingWhileListIsCompact() {
        let status = MCPServerStatus(name: "local", state: .connected, toolCount: 44)
        let compact = UIHostingController(rootView: MCPStatusLabel(status: status).frame(maxWidth: 220))
        let detail = UIHostingController(rootView: MCPStatusLabel(status: status, compact: false).frame(maxWidth: 220))
        let compactSize = compact.sizeThatFits(in: CGSize(width: 110, height: 1000))
        let detailSize = detail.sizeThatFits(in: CGSize(width: 110, height: 1000))
        #expect(compactSize.height > 0 && detailSize.height > compactSize.height)
        #expect(MCPStatusText(status).title == "Connected · 44 tools")
        let failed = MCPServerStatus(name: "local", state: .error, lastError: "The server could not connect")
        #expect(MCPStatusText(failed).detail == "The server could not connect")
    }
}
#endif
