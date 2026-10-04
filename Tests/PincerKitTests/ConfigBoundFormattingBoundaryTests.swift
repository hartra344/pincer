import Foundation
import Testing
import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct ConfigBoundFormattingBoundaryTests {
    private func field(_ bound: String, _ number: Double) throws -> ConfigField {
        try #require(ConfigSchema(schema: ["type": "object", "properties": ["limit": ["type": "number", bound: .number(number)]]]).field(at: ["limit"]))
    }
    @Test func exactIntegerBoundaryAndNeighborRemainSafe() throws {
        let largestRepresentable = Double(Int64.max).nextDown
        let inside = try field("minimum", largestRepresentable)
        #expect(inside.validate(.number(0)) == "Must be at least \(Int64(largestRepresentable)).")
        #expect(inside.validate(.number(largestRepresentable)) == nil)
        let outside = try field("minimum", Double(Int64.max))
        #expect(outside.validate(.number(0)) == "Must be at least \(Double(Int64.max)).")
        #expect(outside.validate(.number(Double(Int64.max))) == nil)
        let negative = try field("maximum", Double(Int64.min))
        #expect(negative.validate(.number(0)) == "Must be at most \(Int64.min).")
        #expect(negative.validate(.number(Double(Int64.min))) == nil)
    }
    @Test func fractionalAndSignedZeroControls() throws {
        #expect(try field("minimum", -2.5).validate(.number(-3)) == "Must be at least -2.5.")
        #expect(try field("maximum", -0.0).validate(.number(1)) == "Must be at most 0.")
    }
}
