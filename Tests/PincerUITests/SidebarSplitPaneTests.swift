import Foundation
import Testing
#if os(macOS)
import AppKit
#endif
@testable import PincerKit
@testable import PincerUI

@Suite
@MainActor
struct SidebarSplitPaneTests {
    @Test func splitPaneObservationTracksGatewayWhenSessionKeysMatch() {
        let firstGateway = SidebarSplitPaneObservation(gatewayID: UUID(), sessionKey: "agent:main:main")
        let secondGateway = SidebarSplitPaneObservation(gatewayID: UUID(), sessionKey: "agent:main:main")

        #expect(firstGateway != secondGateway)
    }

    @Test func actualSidebarModelMarksTheChatShownInTheRightPane() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(
            profile: GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults,
            identity: UIFixtures.identity())
        gateway.applySnapshot(.object([
            "sessions": .array([
                .object(["key": .string("agent:main:main"), "label": .string("Main")]),
                .object(["key": .string("agent:main:dashboard:notes"), "label": .string("Notes")]),
                .object(["key": .string("agent:main:dashboard:other"), "label": .string("Other")]),
            ]),
        ]))
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
        #expect(ChannelRowStyle.accessibilityHint(for: rightPane) == L("Shown in right pane"))

        let samePaneModel = SidebarModel.build(
            gateway: gateway, search: "", collapsed: [], expandedThreads: [],
            showSubagentRuns: false, showPreviews: false, splitKey: "agent:main:main")
        let samePaneSelected = try #require(samePaneModel.groups.flatMap(\.allEntries)
            .first { $0.row.key == "agent:main:main" })
        #expect(samePaneSelected.isShownInSplitPane)

        let hiddenModel = SidebarModel.build(
            gateway: gateway, search: "", collapsed: [], expandedThreads: [],
            showSubagentRuns: false, showPreviews: false, splitKey: nil)
        #expect(hiddenModel.groups.flatMap(\.allEntries).allSatisfy { !$0.isShownInSplitPane })

        #if os(macOS)
        let cell = SidebarChatCell()
        cell.configure(rightPane, actions: self.actions())
        let indicator = Self.descendants(of: cell).first {
            $0.identifier == NSUserInterfaceItemIdentifier("sidebar-split-pane-indicator")
        }
        #expect(indicator?.isHidden == false)
        #expect(cell.accessibilityHelp() == L("Shown in right pane"))
        cell.configure(selected, actions: self.actions())
        #expect(indicator?.isHidden == true)
        #expect(cell.accessibilityHelp() == nil)
        #endif
    }

    private func actions() -> SidebarActions {
        SidebarActions(select: { _ in }, newChat: { _ in }, newChatInGroup: { _, _ in },
                       rename: { _ in }, changeIcon: { _ in }, changeGroupIcon: { _ in }, pickColor: { _ in },
                       prompt: { _ in }, confirm: { _ in }, toggleThreads: { _ in }, setCollapsed: { _, _ in },
                       refresh: {}, openAutomations: {})
    }

    #if os(macOS)
    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }
    #endif
}
