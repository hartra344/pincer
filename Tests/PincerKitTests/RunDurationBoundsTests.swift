import Foundation
import Testing
@testable import PincerKit

@Suite("Runs duration safe bounds", .timeLimit(.minutes(2)))
struct RunDurationBoundsTests {
    @Test(arguments: [1e30, Double(Int.max), Double.greatestFiniteMagnitude])
    func hugeFiniteDurationSaturatesBeforeConversion(interval: Double) {
        #expect(RunDuration.format(interval) == "2562047788015215:30:07")
    }
    @Test func representableBoundaryAndFractionRetainExactFormatting() {
        let representable = Double(Int.max).nextDown
        #expect(RunDuration.format(representable) == "2562047788015215:13:04")
        #expect(RunDuration.format(Double(2_147_483_648) * 3600) == "2147483648:00:00")
        #expect(RunDuration.format(65.9) == "1:05")
        #expect(RunDuration.format(3601.9) == "1:00:01")
        #expect(RunDuration.format(1) == "0:01")
    }
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1, 0, 0.999])
    func nonfiniteAndSubsecondRemainShort(interval: Double) {
        #expect(RunDuration.format(interval) == "<1s")
    }
}
