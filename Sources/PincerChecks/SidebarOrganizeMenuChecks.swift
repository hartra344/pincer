import Foundation
import PincerKit

/// The Organize menu is view options only; the switcher carries the Gateway actions it used to (#955).
@MainActor
func runSidebarOrganizeMenuOfflineChecks() {
    let gatewayTitles: Set = ["Gateway Settings…", "Add Gateway…", "Setup Assistant…", "Automations…",
                              "Approval History…", "Gateway Logs…", "Command Policy…", "Usage & Cost…", "Reconnect"]
    for organization in SidebarOrganization.allCases {
        let titles = Set(SidebarOrganizeMenu.items(organization: organization).map(\.title))
        check(titles.isDisjoint(with: gatewayTitles), "organize menu: no Gateway actions when \(organization.rawValue)")
        check(titles.isSuperset(of: ["Organize", "Show Archived", "Show Automations", "Show Slash Commands"]),
              "organize menu: view options when \(organization.rawValue)")
    }
    check(SidebarOrganizeMenu.items(organization: .group).contains(.newGroup)
        && !SidebarOrganizeMenu.items(organization: .recent).contains(.newGroup),
        "organize menu: New Group… only when grouped")
    check(GatewayMenuModel.gatewayActions.map(\.title)
        == ["Gateway Settings…", "Automations…", "Setup Assistant…", "Reconnect"],
        "organize menu: switcher carries Gateway Settings, Automations, Setup Assistant and Reconnect")
    check(GatewayMenuModel.gatewayActions.filter(\.needsConnection) == [.setupAssistant],
          "organize menu: only Setup Assistant waits for a connection")
}
