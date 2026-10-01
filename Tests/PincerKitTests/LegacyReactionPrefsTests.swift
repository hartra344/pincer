import Foundation
import Testing
@testable import PincerKit

@Suite("Legacy reaction preference size")
struct LegacyReactionPrefsTests {
    private func encodedSize(_ entries: [String: String]) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(entries).count
    }

    @Test func keepsTheCurrentReactionAndFitsTheGatewayValueBudget() throws {
        let currentKey = "agent:main:main|current-reaction"
        var entries = Dictionary(uniqueKeysWithValues: (0..<140).map {
            ("agent:main:main|older-reaction-\($0)", "👍")
        })
        entries[currentKey] = "🧭"

        let fitted = try #require(LegacyReactionPrefs.fitting(entries, preserving: currentKey))
        #expect(fitted[currentKey] == "🧭")
        #expect(try self.encodedSize(fitted) <= LegacyReactionPrefs.syncedByteBudget)
        #expect(fitted.count < entries.count, "other legacy reactions are evicted when the map grows past the Gateway limit")
    }

    @Test func accountsForEscapedAndUnicodeKeysAndValues() throws {
        let currentKey = "agent:main:main|latest\n\"✨"
        var entries = Dictionary(uniqueKeysWithValues: (0..<120).map {
            ("agent:main:main|old-\($0)\n\"", "emoji / quote \"\n • 🧭")
        })
        entries[currentKey] = "✨\n\"/"

        let fitted = try #require(LegacyReactionPrefs.fitting(entries, preserving: currentKey))
        #expect(fitted[currentKey] == "✨\n\"/")
        #expect(try self.encodedSize(fitted) <= LegacyReactionPrefs.syncedByteBudget)
    }

    @Test func evictionIsDeterministicRegardlessOfInsertionOrder() throws {
        let pairs = (0..<120).map { ("agent:main:main|entry-\($0)", "🎉") }
        let forward = Dictionary(uniqueKeysWithValues: pairs)
        let reversed = Dictionary(uniqueKeysWithValues: pairs.reversed())
        let key = "agent:main:main|entry-119"

        let first = try #require(LegacyReactionPrefs.fitting(forward, preserving: key))
        let second = try #require(LegacyReactionPrefs.fitting(reversed, preserving: key))
        #expect(first == second)
        #expect(first[key] == "🎉")
        #expect(try self.encodedSize(first) <= LegacyReactionPrefs.syncedByteBudget)
    }

    @Test func underBudgetMapIsUnchangedAndDeletedProtectedKeyStaysDeleted() throws {
        let small = ["agent:main:main|one": "👍", "agent:main:main|two": "✨"]
        #expect(LegacyReactionPrefs.fitting(small, preserving: "agent:main:main|two") == small)

        let current = "agent:main:main|deleted"
        let oversized = Dictionary(uniqueKeysWithValues: (0..<120).map {
            ("agent:main:main|old-\($0)", "👍")
        })
        let fitted = try #require(LegacyReactionPrefs.fitting(oversized, preserving: current))
        #expect(fitted[current] == nil)
        #expect(try self.encodedSize(fitted) <= LegacyReactionPrefs.syncedByteBudget)
    }

    @Test func refusesAProtectedReactionThatCannotFitByItself() throws {
        let oversizedKey = "agent:main:main|" + String(repeating: "m", count: 4_000)
        let fitted = LegacyReactionPrefs.fitting([oversizedKey: "👍"], preserving: oversizedKey)
        #expect(fitted == nil, "an impossible value must not be reported as synced")
    }
}
