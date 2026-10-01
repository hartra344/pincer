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
