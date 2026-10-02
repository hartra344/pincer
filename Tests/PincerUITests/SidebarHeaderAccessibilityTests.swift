import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

/// #308: sidebar headers name the agent on +, and speak Collapsed/Expanded.
@MainActor
@Suite("Sidebar header accessibility")
struct SidebarHeaderAccessibilityTests {
    private func header(_ kind: SidebarSection.Kind, title: String, collapsed: Bool, agent: String? = nil) -> SidebarModel.Header {
        let section = SidebarSection(id: title, title: title, emoji: nil, channels: [], kind: kind)
        return SidebarModel.Header(id: SidebarModel.headerId(title), section: section, isCollapsed: collapsed, newChatAgent: agent)
    }

    @Test func agentHeaderAddButtonNamesTheAgent() {
        let header = self.header(.agent("mochi"), title: "Mochi", collapsed: false, agent: "mochi")
        #expect(header.addAccessibilityLabel == "New chat with Mochi")
    }

    @Test func plainGroupHeaderAddButtonNamesTheGroup() {
        for group in ["Home", "Personal"] {
            let header = self.header(.group(group), title: group, collapsed: false)
            #expect(header.addAccessibilityLabel == "New chat in \(group)")
            let collapsed = self.header(.group(group), title: group, collapsed: true)
            #expect(collapsed.addAccessibilityLabel == header.addAccessibilityLabel)
        }
    }

    @Test func groupLabelKeepsExistingNewChatTargets() {
        var target = ""
        let actions = SidebarActions(
            select: { _ in },
            newChat: { target = "agent:\($0)" },
            newChatInGroup: { group, agent in target = "group:\(group):\(agent ?? "default")" },
            rename: { _ in }, changeIcon: { _ in }, changeGroupIcon: { _ in }, pickColor: { _ in },
            prompt: { _ in }, confirm: { _ in }, toggleThreads: { _ in }, setCollapsed: { _, _ in },
            refresh: {}, openAutomations: {}
        )

        self.header(.group("Home"), title: "Home", collapsed: false, agent: "main").addAction(actions)?()
        #expect(target == "agent:main")

        var nested = self.header(.agentGroup(agent: "mochi", group: "Prep"), title: "Prep", collapsed: false, agent: "mochi")
        nested.agentName = "Mochi"
        nested.addAction(actions)?()
        #expect(target == "group:Prep:mochi")
    }

    @Test func valueSpeaksDisclosureState() {
        #expect(self.header(.agent("mochi"), title: "Mochi", collapsed: true).accessibilityValue == "Collapsed")
        #expect(self.header(.agent("mochi"), title: "Mochi", collapsed: false).accessibilityValue == "Expanded")
        #expect(self.header(.other, title: "Other", collapsed: true).accessibilityValue == "Collapsed")
    }

    @Test func nestedGroupLabelDoesNotDependOnCollapsedState() {
        var open = self.header(.agentGroup(agent: "mochi", group: "Prep"), title: "Prep", collapsed: false, agent: "mochi")
        open.agentName = "Mochi"
        open.chatCount = 2
        var closed = open
        closed = self.header(.agentGroup(agent: "mochi", group: "Prep"), title: "Prep", collapsed: true, agent: "mochi")
        closed.agentName = "Mochi"
        closed.chatCount = 2
        #expect(open.addAccessibilityLabel == "New chat in Prep with Mochi")
        #expect(closed.addAccessibilityLabel == open.addAccessibilityLabel)
        #expect(open.subsectionAccessibilityLabel.contains("Prep"))
        #expect(!open.subsectionAccessibilityLabel.lowercased().contains("collapsed"))
        #expect(!closed.subsectionAccessibilityLabel.lowercased().contains("collapsed"))
    }
}
