import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

/// #265: an event's section build derives parents at most once for each eligible row.
@MainActor
func runSidebarSectionWorkChecks() {
    #if DEBUG
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: GatewayProfile(name: "Sections", url: "ws://127.0.0.1:1", authMode: .none),
                               defaults: defaults)
    let count = 300
    let rows: [JSONValue] = (0..<count).map { index in
        .object(["key": .string("agent:main:dashboard:chat\(index)"),
                 "label": .string("Chat \(index)"), "updatedAt": .number(Double(index))])
    }
    gateway.applySnapshot(.object(["sessions": .array(rows)]))
    for organization in [SidebarOrganization.recent, .agent, .group, .servers] {
        gateway.organization = organization
        gateway.sidebarParentCandidateDerivationCount = 0
        let sections = gateway.sections()
        let keys = sections.flatMap { $0.channels.flatMap { [$0.row.key] + $0.threads.map(\.key) } }
        check(keys.count == count && Set(keys).count == count,
              "sidebar work: \(organization) preserves all \(count) rows")
        check(gateway.sidebarParentCandidateDerivationCount <= count,
              "sidebar work: \(organization) derives parents once per row (\(gateway.sidebarParentCandidateDerivationCount))")
    }
    #endif
}

/// The existing demo's hidden-parent behavior uses the same section path and stays interactive.
@MainActor
func runDemoSidebarSectionWorkChecks() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.start()
    defer {
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    let ready = await waitFor("demo sidebar section work") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(ready, "sidebar work demo: connected")
    guard ready else { return }
    for organization in [SidebarOrganization.recent, .agent, .group, .servers] {
        gateway.organization = organization
        #if DEBUG
        gateway.sidebarParentCandidateDerivationCount = 0
        #endif
        let sections = gateway.sections()
        let rows = sections.flatMap { $0.channels.flatMap { [$0.row] + $0.threads } }
        check(Set(rows.map(\.key)).count == rows.count && rows.contains { $0.key == "agent:main:main" },
              "sidebar work demo: \(organization) retains main chat with no duplicates")
        #if DEBUG
        check(gateway.sidebarParentCandidateDerivationCount <= gateway.sessions.count,
              "sidebar work demo: \(organization) keeps its per-row derivation budget")
        #endif
    }
}
