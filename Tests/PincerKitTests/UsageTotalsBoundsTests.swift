import Testing
@testable import PincerKit

struct UsageTotalsBoundsTests {
    @Test func oversizedFiniteCountSaturatesWithoutConversionTrap() {
        let totals = UsageTotals(Fixtures.json(#"{"input":1e30}"#))
        #expect(totals.input == Int.max)
        #expect(totals.totalTokens == Int.max)
    }

    @Test func representableCountsSaturateFallbackSum() {
        let totals = UsageTotals(Fixtures.json(#"{"input":4000000000000000000,"output":4000000000000000000,"cacheRead":4000000000000000000,"cacheWrite":4000000000000000000}"#))
        #expect(totals.input == 4_000_000_000_000_000_000)
        #expect(totals.output == totals.input)
        #expect(totals.totalTokens == Int.max)
    }

    @Test func explicitTotalKeepsPrecedenceDespiteLargeComponents() {
        let totals = UsageTotals(Fixtures.json(#"{"input":4000000000000000000,"output":4000000000000000000,"cacheRead":4000000000000000000,"cacheWrite":4000000000000000000,"totalTokens":42,"tokens":99}"#))
        #expect(totals.totalTokens == 42)
    }

    @Test func cacheAndAggregationEndpointsDoNotOverflow() {
        var first = UsageTotals()
        first.input = Int.max
        first.cacheRead = Int.max
        first.cacheWrite = 1
        first.totalTokens = Int.max
        first.missingCostEntries = Int.max
        first.missingCostByModel = ["provider/model": Int.max]
        #expect(first.cacheTokens == Int.max)
        var next = UsageTotals()
        next.input = 1
        next.cacheRead = 1
        next.totalTokens = 1
        next.missingCostEntries = 1
        next.missingCostByModel = ["provider/model": 1]
        let summed = first + next
        #expect(summed.input == Int.max)
        #expect(summed.cacheRead == Int.max)
        #expect(summed.totalTokens == Int.max)
        #expect(summed.missingCostEntries == Int.max)
        #expect(summed.missingCostByModel["provider/model"] == Int.max)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1.0, -1e30])
    func invalidCountsDefaultToZero(_ value: Double) {
        let totals = UsageTotals(.object(["input": .number(value), "totalTokens": .number(value),
                                        "missingCostByModel": .object(["provider/model": .number(value)])]))
        #expect(totals.input == 0 && totals.totalTokens == 0)
        #expect(totals.missingCostByModel["provider/model"] == 0)
    }

    @Test func largestRepresentableDoubleBelowIntegerLimitConvertsExactly() {
        let value = Double(Int.max).nextDown
        let totals = UsageTotals(.object(["input": .number(value)]))
        #expect(totals.input == Int(value))
        #expect(totals.totalTokens == Int(value))
    }

    @Test func maximumBoundaryAndMissingModelCountsAreBounded() {
        let totals = UsageTotals(.object(["input": .number(Double(Int.max)),
            "missingCostEntries": .number(1e30), "missingCostByModel": .object(["provider/model": .number(1e30)])]))
        #expect(totals.input == Int.max && totals.missingCostEntries == Int.max)
        #expect(totals.missingCostByModel["provider/model"] == Int.max)
        var negative = UsageTotals()
        negative.input = Int.min
        negative.cacheRead = Int.min
        #expect((negative + .zero).input == 0 && negative.cacheTokens == 0)
    }

    @Test func ordinaryRoundingFallbackAndExplicitTotalsRemainUnchanged() {
        let summed = UsageTotals(Fixtures.json(#"{"input":10.6,"output":2.4,"cacheRead":3,"cacheWrite":4}"#))
        #expect(summed.input == 11 && summed.output == 2)
        #expect(summed.totalTokens == 20 && summed.cacheTokens == 7)
        let explicit = UsageTotals(Fixtures.json(#"{"input":1,"totalTokens":99.4,"tokens":42}"#))
        #expect(explicit.totalTokens == 99)
        #expect(UsageTotals(Fixtures.json(#"{"tokens":42}"#)).totalTokens == 42)
        #expect(UsageTotals(nil) == .zero)
    }
}
