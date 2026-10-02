import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@Suite
@MainActor
struct SidebarSplitPaneTests {
    @Test func actualSidebarModelMarksTheChatShownInTheRightPane() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults,
            identity: UIFixtures.identity())
        gateway.applySnapshot(Fixtures.json(#"{"sessions":[{"key":"agent:main:main","label":"Main"},{"key":"agent:main:dashboard:notes","label":"Notes"},{"key":"agent:main:dashboard:other","label":"Other"}]}"#))
        gateway.selectedKey = "agent:main:main"
        gateway.openInSplit("agent:main:dashboard:notes")

        let model = SidebarModel.build(
            gateway: gateway, search: "", collapsed: [], expandedThreads: [],
            showSubagentRuns: false, showPreviews: false, splitKey: gateway.visibleSplitKey)
        let entries = model.groups.flatMap(\.allEntries)
        let rightPane = try #require(entries.first { $0.row.key == "agent:main:dashboard:notes" })
        let selected = try #require(entries.first { $0.row.key == "agent:main:main" })
        let other = try #require(entries.first { $0.row.key == "agent:main:dashboard:other" })

        #expect(rightPane.isShownInSplitPane)
        #expect(!selected.isShownInSplitPane)
        #expect(!other.isShownInSplitPane)
    }
}
