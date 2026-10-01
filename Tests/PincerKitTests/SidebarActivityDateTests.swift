import Foundation
import Testing
@testable import PincerKit

@Suite("Sidebar activity dates")
struct SidebarActivityDateTests {
    @Test func futureActivityUsesNowLabel() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expected = L("now")

        for offset in [0.1, 1, 60, 86_400] {
            let date = now.addingTimeInterval(offset)
            #expect(SidebarActivityDate.relativeDate(date, now: now) == expected,
                    "future activity at +\(offset)s should use the now label")
            #expect(!SidebarActivityDate.relativeDate(date, now: now).contains("in 0"),
                    "future activity at +\(offset)s should not show a zero-duration label")
        }
    }

    @Test func pastActivityKeepsExistingRelativeFormatting() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for offset in [1.0, 60, 3_600, 86_400] {
            let date = now.addingTimeInterval(-offset)
            let previous = date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
            #expect(SidebarActivityDate.relativeDate(date, now: now) == previous,
                    "past activity at -\(offset)s should keep its existing label")
        }
    }
}
