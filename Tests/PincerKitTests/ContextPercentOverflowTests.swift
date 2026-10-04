import Testing
@testable import PincerKit

struct ContextPercentOverflowTests {
    private static func row(used: Double, limit: Double?) -> SessionRow? {
        var json: [String: JSONValue] = ["key": .string("agent:main:context-percent"), "totalTokens": .number(used)]
        if let limit { json["contextTokens"] = .number(limit) }
        return SessionRow(.object(json))
    }

    @Test func hugeAcceptedSessionTokensClampBeforeIntegerConversion() throws {
        let row = try #require(Self.row(used: 1e18, limit: 1))
        #expect(row.totalTokens == 1_000_000_000_000_000_000)
        let usage = try #require(ContextUsage(row: row))
        #expect(usage.limit == 1)
        #expect(usage.percent == 100)
        #expect(usage.percentLabel == "100%")
        #expect(AccessibilityText.contextMeterValue(usage).hasPrefix("100 percent used"))
    }

    @Test(arguments: [(0.0, 0), (50.0, 50), (100.0, 100), (300.0, 100)])
    func ordinaryAndOverLimitRows(used: Double, expected: Int) throws {
        let row = try #require(Self.row(used: used, limit: 100))
        let usage = try #require(ContextUsage(row: row))
        #expect(usage.percent == expected)
        #expect(usage.percentLabel == "\(expected)%")
    }

    @Test func directConstructorExtremesRemainSafe() {
        #expect(ContextUsage(used: Int.max, limit: 1).percent == 100)
        #expect(ContextUsage(used: Int.max, limit: Int.max).percent == 100)
        #expect(ContextUsage(used: 1, limit: Int.max).percent == 0)
        #expect(ContextUsage(used: Int.min, limit: 1).percent == 0)
        #expect(ContextUsage(used: Int.max, limit: 0).percent == 0)
        #expect(ContextUsage(used: Int.max, limit: Int.min).percent == 0)
        #expect(ContextUsage(used: 0, limit: 0).percent == 0)
        #expect(ContextUsage(used: 1, limit: 200).percent == 1)
        #expect(ContextUsage(used: 199, limit: 200).percent == 100)
    }

    @Test func unknownOrInvalidContextDoesNotProduceMeter() throws {
        #expect(ContextUsage(row: nil) == nil)
        let unknown = try #require(Self.row(used: 50, limit: nil))
        #expect(ContextUsage(row: unknown) == nil)
        let zeroLimit = try #require(Self.row(used: 50, limit: 0))
        #expect(ContextUsage(row: zeroLimit) == nil)
        let negativeUsed = try #require(Self.row(used: -1, limit: 100))
        #expect(ContextUsage(row: negativeUsed) == nil)
        #expect(ContextUsage(row: unknown, fallbackLimit: 100)?.percent == 50)
    }
}
