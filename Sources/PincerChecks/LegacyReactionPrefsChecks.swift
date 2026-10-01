import Foundation
import PincerKit

@MainActor
func checkLegacyReactionPrefs() {
    let current = "agent:main:main|current"
    var entries = Dictionary(uniqueKeysWithValues: (0..<120).map {
        ("agent:main:main|older-\($0)\n\"", "👍 / \"✨")
    })
    entries[current] = "🧭"
    guard let fitted = LegacyReactionPrefs.fitting(entries, preserving: current) else {
        check(false, "legacy reaction pref can fit the current value")
        return
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let byteCount = (try? encoder.encode(fitted).count) ?? Int.max
    check(byteCount <= LegacyReactionPrefs.syncedByteBudget, "legacy reaction pref respects the 3,800-byte budget (\(byteCount))")
    check(fitted[current] == "🧭" && fitted.count < entries.count, "fitting retains the current reaction and trims other map entries")
    check(LegacyReactionPrefs.fitting(["small": "👍"], preserving: "small") == ["small": "👍"],
          "an under-budget legacy reaction map is unchanged")
}
