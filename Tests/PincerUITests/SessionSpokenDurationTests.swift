import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI

@MainActor @Suite(.timeLimit(.minutes(2)))
struct SessionSpokenDurationTests {
    @Test func actualRowSpokenDurationAcceptsLargeFiniteRuntime() throws {
        let row = try #require(SessionRow(["key": "local-duration", "runtimeMs": .number(1e30)]))
        let elapsed = try #require(SessionManager.runDuration(row, now: Date(timeIntervalSince1970: 0)))
        #expect(elapsed == 1e30 / 1000)
        #expect(!SessionManagerRowView.spokenDuration(elapsed).isEmpty)
    }
    @Test func ordinaryAndNegativeSpokenControls() throws {
        let row = try #require(SessionRow(["key": "ordinary-duration", "runtimeMs": 94000]))
        let elapsed = try #require(SessionManager.runDuration(row, now: Date(timeIntervalSince1970: 0)))
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
        #expect(SessionManagerRowView.spokenDuration(elapsed) == Duration.seconds(94).formatted(style))
        #expect(SessionManagerRowView.spokenDuration(-5) == Duration.seconds(0).formatted(style))
    }
}
