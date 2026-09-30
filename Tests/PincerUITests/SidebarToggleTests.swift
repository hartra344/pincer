import SwiftUI
import Testing
@testable import PincerUI

/// The iPad "Show Sidebar" button and ⌃⌘S toggle the split view's columns (#564).
struct SidebarToggleTests {
    @Test func hiddenSidebarComesBackBesideTheChat() {
        #expect(SidebarToggle.toggled(.detailOnly) == .all)
    }

    @Test func shownSidebarHides() {
        #expect(SidebarToggle.toggled(.all) == .detailOnly)
        #expect(SidebarToggle.toggled(.automatic) == .detailOnly)
        #expect(SidebarToggle.toggled(.doubleColumn) == .detailOnly)
    }

    @Test func titleFollowsTheSidebar() {
        #expect(SidebarToggle(isCollapsed: true, toggle: {}).title == "Show Sidebar")
        #expect(SidebarToggle(isCollapsed: false, toggle: {}).title == "Hide Sidebar")
    }
}
