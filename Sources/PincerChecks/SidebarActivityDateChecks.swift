import Foundation
import PincerKit

@MainActor
func runSidebarActivityDateChecks() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expected = String(localized: "now", bundle: PincerStrings.bundle ?? .main)

    for offset in [0.1, 1, 60, 86_400] {
        let formatted = SidebarActivityDate.relativeDate(now.addingTimeInterval(offset), now: now)
        check(formatted == expected && !formatted.contains("in 0"),
              "sidebar activity date: +\(offset)s formats as now (got \(formatted))")
    }

    for offset in [1.0, 60, 3_600, 86_400] {
        let date = now.addingTimeInterval(-offset)
        let previous = date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
        check(SidebarActivityDate.relativeDate(date, now: now) == previous,
              "sidebar activity date: -\(offset)s keeps its previous relative label")
    }
}

@MainActor
func runDemoSidebarActivityDateChecks() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    gateway.reconnectIfNeeded()
    let ready = await waitFor("demo sidebar activity date") {
        gateway.state.isConnected && gateway.sessions["agent:coder:dashboard:retry-fix"]?.activityDate != nil
    }
    check(ready, "sidebar activity date: demo connects with a seeded activity timestamp")
    guard ready, let date = gateway.sessions["agent:coder:dashboard:retry-fix"]?.activityDate else {
        gateway.stop()
        return
    }
    defer { gateway.stop() }

    let justBefore = date.addingTimeInterval(-0.1)
    let expected = String(localized: "now", bundle: PincerStrings.bundle ?? .main)
    check(SidebarActivityDate.relativeDate(date, now: justBefore) == expected,
          "sidebar activity date: a seeded session timestamp just ahead of now uses the now label")
}
