import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct SessionSpokenDurationBoundaryTests {
    @Test func legalFiniteRowReachesActualSpokenFormatter() throws {
        let row = try #require(SessionRow(["key": "local-duration", "runtimeMs": .number(1e30)]))
        let elapsed = try #require(SessionManager.runDuration(row, now: Date(timeIntervalSince1970: 0)))
        #expect(elapsed == 1e30 / 1000)
        #expect(!SessionManager.spokenDuration(elapsed).isEmpty)
    }
    @Test func ordinarySpokenDurationRemainsExact() {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
        #expect(SessionManager.spokenDuration(94) == Duration.seconds(94).formatted(style))
        #expect(SessionManager.spokenDuration(-5) == Duration.seconds(0).formatted(style))
    }
}
