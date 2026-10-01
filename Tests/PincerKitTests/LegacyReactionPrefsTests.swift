import Foundation
import Testing
@testable import PincerKit

@Suite("Legacy reaction preference size")
struct LegacyReactionPrefsTests {
    @Test func keepsTheCurrentReactionAndFitsTheGatewayValueBudget() throws {
        let currentKey = "agent:main:main|current-reaction"
        var entries = Dictionary(uniqueKeysWithValues: (0..<140).map {
            ("agent:main:main|older-reaction-\($0)", "👍")
        })
        entries[currentKey] = "🧭"

        let fitted = try #require(LegacyReactionPrefs.fitting(entries, preserving: currentKey))
        #expect(fitted[currentKey] == "🧭")
        #expect(try JSONEncoder().encode(fitted).count <= LegacyReactionPrefs.syncedByteBudget)
        #expect(fitted.count < entries.count, "older legacy reactions are evicted when the map grows past the Gateway limit")
    }

    @Test func refusesAProtectedReactionThatCannotFitByItself() throws {
        let oversizedKey = "agent:main:main|" + String(repeating: "m", count: 4_000)
        let fitted = LegacyReactionPrefs.fitting([oversizedKey: "👍"], preserving: oversizedKey)
        #expect(fitted == nil, "an impossible value must not be reported as synced")
    }
}
