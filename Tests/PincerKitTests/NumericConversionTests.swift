import Foundation
import Testing
@testable import PincerKit

/// #925: one documented policy for gateway Double→Int conversions.
@Suite("Numeric conversion policy")
struct NumericConversionTests {
    @Test func nonFiniteIsAbsent() {
        for value in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            #expect(Int(saturating: value) == nil)
            #expect(Int(saturating: value, rounding: .towardZero) == nil)
            #expect(value.integerString() == nil)
            #expect(value.integerString(rounding: .towardZero) == nil)
        }
    }

    @Test func finiteValuesClampAtBothEnds() {
        #expect(Int(saturating: Double(Int.max)) == .max)
        #expect(Int(saturating: Double(Int.max).nextDown) == Int(exactly: Double(Int.max).nextDown))
        #expect(Int(saturating: .greatestFiniteMagnitude) == .max)
        #expect(Int(saturating: Double(Int.min)) == .min)
        #expect(Int(saturating: -.greatestFiniteMagnitude) == .min)
        #expect(Int(saturating: -0.0) == 0)
    }

    @Test func roundingRuleApplies() {
        #expect(Int(saturating: 1.5) == 2)
        #expect(Int(saturating: -1.5) == -2)
        #expect(Int(saturating: 1.9, rounding: .towardZero) == 1)
        #expect(Int(saturating: -1.9, rounding: .towardZero) == -1)
        #expect(Int(saturating: 1.9, rounding: .down) == 1)
    }

    @Test func integerStringIsExactAndNeverClamps() {
        #expect(42.0.integerString() == "42")
        #expect((-7.0).integerString() == "-7")
        #expect(1.5.integerString() == nil)
        #expect(1.5.integerString(rounding: .towardZero) == "1")
        #expect(1e30.integerString(rounding: .towardZero) == nil, "distinct huge identities must not collapse to Int.max")
        #expect(Double(Int.max).integerString() == nil)
    }

    @Test func migratedCallSitesFollowThePolicy() {
        #expect(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": .number(.infinity)]) == nil)
        #expect(GatewayHealthModel.restartExpectedMs(shutdown: ["restartExpectedMs": .number(1e30)]) == .max)
        #expect(SessionManager.formatDuration(.infinity) == SessionManager.formatDuration(0))
        #expect(RunDuration.format(.infinity) == "<1s")
        #expect(RunDuration.format(1e30) == RunDuration.format(Double(Int.max)))
        #expect(UsageFormat.percent(.nan) == "0%")
        #expect(UsageFormat.percent(99.6) == "100%")
        #expect(ActivityNotificationIdentity.make(key: "k", activityMs: 1_700_000_000_123.9) == "reply:k:1700000000123")
        #expect(ActivityNotificationIdentity.make(key: "k", activityMs: 1e30) == "reply:k:\(String(1e30))")
    }

    /// Repro: `UsageFormat.duration(ms:)` did `Int(seconds)` on a gateway `durationMs`, which traps on
    /// huge or non-finite values.
    @Test func sessionUsageDurationSurvivesHostileValues() {
        #expect(UsageFormat.duration(ms: .nan) == "<1m")
        #expect(UsageFormat.duration(ms: .infinity) == "<1m")
        #expect(UsageFormat.duration(ms: -.infinity) == "<1m")
        #expect(UsageFormat.duration(ms: 1e30).hasSuffix("d") || UsageFormat.duration(ms: 1e30).hasSuffix("h"))
        #expect(UsageFormat.duration(ms: 4_320_000) == "1h 12m")
    }
}
