import Foundation
import Testing
@testable import PincerKit

@Suite("Organize menu and switcher actions")
struct SidebarOrganizeMenuTests {
    @Test func organizeHoldsOnlyViewOptions() {
        for organization in SidebarOrganization.allCases {
            let items = SidebarOrganizeMenu.items(organization: organization)
            #expect(Array(items.prefix(4)) == [.organization, .showArchived, .showAutomations, .showSlashCommands])
            #expect(Set(items).isSubset(of: Set(SidebarOrganizeMenu.Item.allCases)))
        }
        let titles = SidebarOrganizeMenu.Item.allCases.map(\.title)
        for gatewayItem in ["Gateway Settings…", "Add Gateway…", "Setup Assistant…", "Automations…", "Approval History…",
                            "Gateway Logs…", "Command Policy…", "Usage & Cost…", "Reconnect"]
        {
            #expect(!titles.contains(gatewayItem))
        }
    }

    @Test func newGroupOnlyWhenGrouped() {
        #expect(SidebarOrganizeMenu.items(organization: .group).last == .newGroup)
        #expect(SidebarOrganizeMenu.items(organization: .servers).last == .newGroup)
        #expect(!SidebarOrganizeMenu.items(organization: .agent).contains(.newGroup))
        #expect(!SidebarOrganizeMenu.items(organization: .recent).contains(.newGroup))
    }

    @Test func switcherCarriesTheGatewayActions() {
        #expect(GatewayMenuModel.gatewayActions == [.gatewaySettings, .automations, .setupAssistant, .reconnect])
        #expect(GatewayMenuModel.gatewayActions.map(\.title)
            == ["Gateway Settings…", "Automations…", "Setup Assistant…", "Reconnect"])
        #expect(GatewayMenuModel.gatewayActions.filter(\.needsConnection) == [.setupAssistant])
    }
}
