import Foundation
import Testing
@testable import PincerKit

/// #234: search date labels agree with the chat ("Yesterday").
@Suite("Search date labels")
struct SearchDateLabelTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    let now = Date(timeIntervalSince1970: 1_790_434_800) // Sat Sep 26 2026 15:00 UTC

    func label(daysAgo: Double) -> String {
        MessageSearch.dateLabel(self.now.addingTimeInterval(-daysAgo * 86400), now: self.now, calendar: self.calendar,
                                locale: Locale(identifier: "en_US")).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func yesterdayIsYesterday() { #expect(self.label(daysAgo: 1) == "Yesterday") }
    @Test func yesterdayEarlyMorning() {
        let early = Date(timeIntervalSince1970: 1_790_294_400 + 60) // Fri Sep 25 00:01 UTC
        #expect(MessageSearch.dateLabel(early, now: self.now, calendar: self.calendar, locale: Locale(identifier: "en_US")) == "Yesterday")
    }
    @Test func threeDaysAgoIsWeekday() { #expect(self.label(daysAgo: 3) == "Wednesday") }
    @Test func sameYearIsMonthDay() { #expect(self.label(daysAgo: 30) == "Aug 27") }
    @Test func todayIsTime() { #expect(self.label(daysAgo: 0.1).contains(":")) }
}
