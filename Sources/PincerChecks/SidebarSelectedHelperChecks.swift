import Foundation
#if DEBUG
@testable import PincerKit

/// #189: selecting a helper keeps it listed even when its parent automation is hidden.
@MainActor
func runSidebarSelectedHelperChecks() {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = GatewayProfile(name: "Selected helper check", url: "ws://127.0.0.1:1", authMode: .none)
    let gateway = GatewayStore(profile: profile, defaults: defaults, identity: DeviceIdentity(privateKey: .init()))
    let automation = "agent:main:cron:briefing"
    let helper = "agent:main:subagent:briefing"
    let snapshot: JSONValue = ["sessions": [
        ["key": "agent:main:main", "updatedAt": 1],
        ["key": .string(automation), "label": "Briefing", "updatedAt": 2],
        ["key": .string(helper), "label": "Briefing helper", "spawnedBy": .string("\(automation):run:run1"), "updatedAt": 3],
    ]]
    gateway.applySnapshot(snapshot)

    let organizations: [SidebarOrganization] = [.recent, .agent, .group, .servers]
    func keys(in store: GatewayStore) -> [SidebarOrganization: Set<String>] {
        var result: [SidebarOrganization: Set<String>] = [:]
        for organization in organizations {
            store.organization = organization
            result[organization] = Set(store.sections().flatMap { section in
                section.channels.flatMap { [$0.row.key] + $0.threads.map(\.key) }
            })
        }
        return result
    }

    check(!gateway.showAutomations, "selected helper: parent automations are hidden by default")
    check(gateway.sessions[automation]?.isAutomation == true && gateway.sessions[helper]?.isSubagent == true,
          "selected helper: fixture contains an automation and its spawned helper")
    gateway.selectedKey = helper
    let selected = keys(in: gateway)
    check(selected.values.allSatisfy { $0.contains(helper) && !$0.contains(automation) },
          "selected helper stays listed while its parent automation stays hidden in every organization")

    gateway.selectedKey = "agent:main:main"
    let unselected = keys(in: gateway)
    check(unselected.values.allSatisfy { !$0.contains(helper) && !$0.contains(automation) },
          "unselected helper remains hidden with its parent in every organization")
}
#else
import PincerKit

@MainActor
func runSidebarSelectedHelperChecks() {}
#endif
