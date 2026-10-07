import Foundation
import Testing
@testable import PincerKit

struct BackgroundRefreshLastCheckTests {
    @Test func exactSavedValuesAndMissingDate() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        #expect(BackgroundRefreshLastCheck(defaults: scratch.defaults).date == nil)
        #expect(BackgroundRefreshLastCheck(defaults: scratch.defaults).result.isEmpty)
        let date = Date(timeIntervalSince1970: 1234)
        scratch.defaults.set(date, forKey: "pincer.refresh.lastRun")
        scratch.defaults.set("Up to date", forKey: "pincer.refresh.lastResult")
        let saved = BackgroundRefreshLastCheck(defaults: scratch.defaults)
        #expect(saved.date == date && saved.result == "Up to date")
    }
}
