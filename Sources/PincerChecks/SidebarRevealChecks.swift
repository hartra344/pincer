import Foundation
import PincerKit

// #306 #307: opening a chat from a link or notification expands the collapsed sections that hide it.

@MainActor
func runDemoSidebarReveal() async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let homeLab = "agent:main:discord:channel:123"
    guard let link = URL(string: "pincer://open?gateway=demo&session=\(homeLab)").flatMap(PincerRoute.parse)
    else { return check(false, "reveal: demo link parses") }
    _ = app.open(link)
    guard let demo = app.gateways.first(where: \.profile.isDemo) else { return check(false, "reveal: link adds the demo") }
    let ready = await waitFor("demo for reveal") { demo.state.isConnected && !demo.sessions.isEmpty && !demo.agents.isEmpty }
    check(ready, "reveal: demo connected")
    guard ready else { return }

    for organization in [SidebarOrganization.agent, .group, .servers] {
        demo.organization = organization
        let ancestors = demo.sidebarAncestors(of: homeLab)
        check(!ancestors.isEmpty, "reveal (\(organization)): home-lab sits in a section (\(ancestors))")
        for id in ancestors { demo.setSectionCollapsed(id, true) }
        check(ancestors.allSatisfy(demo.collapsedSections.contains), "reveal (\(organization)): sections start collapsed")
        _ = app.open(link)
        check(ancestors.allSatisfy { !demo.collapsedSections.contains($0) },
              "reveal (\(organization)): opening the chat expands its sections (\(demo.collapsedSections))")
        check(!demo.revealInSidebar(homeLab), "reveal (\(organization)): nothing left to reveal")
    }
    demo.organization = .recent
    check(demo.sidebarAncestors(of: homeLab).isEmpty && !demo.revealInSidebar(homeLab), "reveal: recent has no sections to open")
}
