import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// #309: the home chat's group action explains why its position is unchanged in By agent.
@MainActor
@Suite("Sidebar home chat group menu")
struct SidebarHomeGroupMenuTests {
    @Test func menuCaptionNamesWhereHomeChatGroupsAppear() throws {
        try Self.verifyMenuCaptions()
    }

    static func verifyMenuCaptions() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(
            profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
            defaults: scratch.defaults, identity: UIFixtures.identity()
        )
        gateway.groupCatalog = ["Work"]
        let rowJSON: JSONValue = ["key": "agent:mochi:main", "category": "Work"]
        let row = try #require(SessionRow(rowJSON))

        let byAgent = self.groupMenuTitle(row: row, gateway: gateway, organization: .agent)
        let byGroup = self.groupMenuTitle(row: row, gateway: gateway, organization: .group)
        let ordinaryJSON: JSONValue = ["key": "agent:mochi:dashboard:inbox", "category": "Work"]
        let ordinary = try #require(SessionRow(ordinaryJSON))
        let ordinaryByAgent = self.groupMenuTitle(row: ordinary, gateway: gateway, organization: .agent)
        #expect(byAgent == L("Move to Group (shown in By Group)"))
        #expect(byGroup == L("Move to Group"), "the normal group view keeps the existing caption")
        #expect(ordinaryByAgent == L("Move to Group"), "non-home chats keep the existing caption")
    }

    private static func groupMenuTitle(row: SessionRow, gateway: GatewayStore, organization: SidebarOrganization) -> String? {
        let actions = SidebarActions(
            select: { _ in }, newChat: { _ in }, newChatInGroup: { _, _ in },
            rename: { _ in }, changeIcon: { _ in }, changeGroupIcon: { _ in }, pickColor: { _ in },
            prompt: { _ in }, confirm: { _ in }, toggleThreads: { _ in }, setCollapsed: { _, _ in },
            refresh: {}, openAutomations: {}
        )
        let items = SidebarMenus.chat(row, gateway: gateway, organization: organization, actions: actions)
        #if os(macOS)
        let menu = NSMenu(title: "Chat")
        SidebarMenuBuilder.populate(menu, items)
        return menu.items.first { $0.submenu?.items.contains { $0.title == "Work" } == true }?.title
        #elseif os(iOS)
        let menu = SidebarMenuBuilder.menu(items)
        return self.submenuTitle(containing: "Work", in: menu)
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private static func submenuTitle(containing itemTitle: String, in menu: UIMenu,
                                     titledAncestor: String? = nil) -> String? {
        for element in menu.children {
            if let action = element as? UIAction, action.title == itemTitle { return titledAncestor }
            guard let submenu = element as? UIMenu else { continue }
            let owner = submenu.title.isEmpty || submenu.options.contains(.displayInline)
                ? titledAncestor
                : submenu.title
            if let nested = self.submenuTitle(containing: itemTitle, in: submenu, titledAncestor: owner) {
                return nested
            }
        }
        return nil
    }
    #endif
}
