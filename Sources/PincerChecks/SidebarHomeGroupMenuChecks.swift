import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

@MainActor
func runSidebarHomeGroupMenuChecks() {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: GatewayProfile(name: "Home groups", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: defaults)
    gateway.groupCatalog = ["Work"]
    let homeKey = "agent:mochi:main"
    let otherKey = "agent:mochi:dashboard:inbox"
    gateway.setSession(SessionRow(["key": .string(homeKey), "agentId": "mochi", "isMain": true,
                                   "category": "Work", "updatedAt": 2]), for: homeKey)
    gateway.setSession(SessionRow(["key": .string(otherKey), "agentId": "mochi",
                                   "category": "Work", "updatedAt": 1]), for: otherKey)

    gateway.organization = .agent
    let byAgent = gateway.sections().first { $0.kind == .agent("mochi") }
    check(byAgent?.channels.first?.row.key == homeKey && byAgent?.leadingChannelCount == 1,
          "sidebar group: an assigned home chat remains in the agent's leading home slot")
    check(byAgent?.subsections.first?.channels.map(\.row.key) == [otherKey],
          "sidebar group: the ordinary grouped chat remains nested under its group")
    check(gateway.groupOrder("Work").contains(homeKey),
          "sidebar group: the home chat retains its actual group membership/order data")

    gateway.organization = .group
    let byGroup = gateway.sections().first { $0.kind == .group("Work") }
    check(Set(byGroup?.channels.map(\.row.key) ?? []) == Set([homeKey, otherKey]),
          "sidebar group: both assigned chats appear in the By group section")
    #endif
}
