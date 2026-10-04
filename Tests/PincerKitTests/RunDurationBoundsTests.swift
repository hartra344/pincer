import Foundation
import Testing
@testable import PincerKit

@Suite("Runs duration safe bounds", .timeLimit(.minutes(2)))
struct RunDurationBoundsTests {
    private func existingFormat(_ total: Int) -> String {
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
    @Test(arguments: [1e30, Double(Int.max), Double.greatestFiniteMagnitude])
    func hugeFiniteDurationSaturatesBeforeConversion(interval: Double) {
        #expect(RunDuration.format(interval) == existingFormat(Int.max))
    }
    @Test func representableBoundaryAndFractionRetainExactFormatting() {
        let representable = Double(Int.max).nextDown
        #expect(RunDuration.format(representable) == existingFormat(Int(representable)))
        #expect(RunDuration.format(65.9) == "1:05")
        #expect(RunDuration.format(3601.9) == "1:00:01")
        #expect(RunDuration.format(1) == "0:01")
    }
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1, 0, 0.999])
    func nonfiniteAndSubsecondRemainShort(interval: Double) {
        #expect(RunDuration.format(interval) == "<1s")
    }
}
