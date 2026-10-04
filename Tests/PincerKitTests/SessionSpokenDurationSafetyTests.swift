import Foundation
import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct SessionSpokenDurationSafetyTests {
    @Test(arguments: [1e30, Double.greatestFiniteMagnitude, Double(Int.max)])
    func oversizedFiniteSecondsSaturate(seconds: Double) {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
        #expect(SessionManager.spokenDuration(seconds) == Duration.seconds(Int.max).formatted(style))
        #expect(SessionManager.formatDuration(seconds) == "\(Int.max / 3600) hr \((Int.max % 3600) / 60) min")
    }
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -Double.greatestFiniteMagnitude, 0])
    func localInvalidSecondsUseZero(seconds: Double) {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
        #expect(SessionManager.spokenDuration(seconds) == Duration.seconds(0).formatted(style))
        #expect(SessionManager.formatDuration(seconds) == "0 sec")
    }
    @Test func ordinaryFloorAndRepresentableBoundaryRemainExact() {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
        for value in [0.9, 94.9, Double(Int.max).nextDown] {
            #expect(SessionManager.spokenDuration(value) == Duration.seconds(Int(value)).formatted(style))
        }
        #expect(SessionManager.formatDuration(94.9) == "1 min 34 sec")
    }
}
