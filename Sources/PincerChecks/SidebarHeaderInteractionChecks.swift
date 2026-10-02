import PincerKit

/// The native keyboard tests exercise event delivery. These demo checks exercise the same
/// collapse action's store boundary without changing the current chat or losing section identity.
@MainActor
func runDemoSidebarHeaderInteractions() async {
    let (defaults, suite) = scratchDefaults()
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.start()
    defer {
        gateway.stop()
        defaults.removePersistentDomain(forName: suite)
    }
    let ready = await waitFor("demo sidebar header actions") {
        gateway.state.isConnected && !gateway.sessions.isEmpty && !gateway.agents.isEmpty
    }
    check(ready, "sidebar headers demo: connected")
    guard ready else { return }
    gateway.selectedKey = "agent:mochi:main"
    let selected = gateway.selectedKey
    for organization in [SidebarOrganization.agent, .group] {
        gateway.organization = organization
        guard let section = gateway.sections().first(where: { !$0.allChannels.isEmpty }) else {
            check(false, "sidebar headers demo: section available in \(organization)")
            continue
        }
        gateway.setSectionCollapsed(section.id, true)
        check(gateway.collapsedSections.contains(section.id), "sidebar headers demo: collapse applies in \(organization)")
        check(gateway.selectedKey == selected, "sidebar headers demo: collapsing preserves the current chat")
        gateway.setSectionCollapsed(section.id, false)
        check(!gateway.collapsedSections.contains(section.id), "sidebar headers demo: expand applies in \(organization)")
        check(gateway.selectedKey == selected && gateway.sections().contains { $0.id == section.id },
              "sidebar headers demo: expansion preserves selection and section identity")
    }
}
