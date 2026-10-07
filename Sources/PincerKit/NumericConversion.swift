import Foundation

// One policy for turning protocol numbers (JSON Doubles from the Gateway) into Ints:
// - Non-finite (NaN, ±infinity) is *absent*: the helpers return nil and the caller decides what
//   absent means (a 0 count, no delay, a fallback label). Never Int.max, never a crash.
// - Finite values are rounded with the given rule, then clamp to Int.min...Int.max.
// `Int(someDouble)` traps on both, so gateway-provided values go through these instead.

extension Int {
    /// `value` rounded with `rule` and clamped to Int's range; nil when `value` isn't finite.
    public init?(saturating value: Double, rounding rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) {
        guard value.isFinite else { return nil }
        let rounded = value.rounded(rule)
        // Double(Int.max) is 2^63, one past Int.max; Double(Int.min) is exactly -2^63.
        if rounded >= Double(Int.max) {
            self = .max
        } else if rounded <= Double(Int.min) {
            self = .min
        } else {
            self = Int(rounded)
        }
    }
}

extension Double {
    /// The integer text of this number ("42", not "42.0"), or nil when there isn't one: not finite,
    /// fractional (with no `rule`), or outside Int's range after rounding. Doesn't clamp, so distinct
    /// large values used as identities stay distinct; callers fall back to `String(self)`.
    public func integerString(rounding rule: FloatingPointRoundingRule? = nil) -> String? {
        guard self.isFinite else { return nil }
        let value = rule.map { self.rounded($0) } ?? self
        return Int(exactly: value).map { String($0) }
    }
}
