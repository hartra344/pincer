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

    @Test func valueSpeaksDisclosureState() {
        #expect(self.header(.agent("mochi"), title: "Mochi", collapsed: true).accessibilityValue == "Collapsed")
        #expect(self.header(.agent("mochi"), title: "Mochi", collapsed: false).accessibilityValue == "Expanded")
        #expect(self.header(.other, title: "Other", collapsed: true).accessibilityValue == "Collapsed")
    }

    @Test func nestedGroupLabelDoesNotDependOnCollapsedState() {
        var open = self.header(.agentGroup(agent: "mochi", group: "Prep"), title: "Prep", collapsed: false)
        open.agentName = "Mochi"
        open.chatCount = 2
        var closed = open
        closed = SidebarModel.Header(id: open.id, section: open.section, isCollapsed: true, newChatAgent: nil)
        closed.agentName = "Mochi"
        closed.chatCount = 2
        #expect(open.subsectionAccessibilityLabel.contains("Prep"))
        #expect(!open.subsectionAccessibilityLabel.lowercased().contains("collapsed"))
        #expect(!closed.subsectionAccessibilityLabel.lowercased().contains("collapsed"))
    }
}
