import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor @Suite(.timeLimit(.minutes(2)))
struct SessionSpokenDurationUISafetyTests {
    @Test func actualRowFormatterRetainsOrdinaryUnitsAndSafeBounds() {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
        #expect(SessionManagerRowView.spokenDuration(94.9) == Duration.seconds(94).formatted(style))
        #expect(SessionManagerRowView.spokenDuration(1e30) == Duration.seconds(Int.max).formatted(style))
        #expect(SessionManagerRowView.spokenDuration(.nan) == Duration.seconds(0).formatted(style))
    }
}
