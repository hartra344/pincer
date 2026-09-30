import Foundation
import Testing
@testable import PincerKit

/// Touches UserDefaults.standard, so it restores whatever was stored.
@Suite("Dictation preferences", .serialized)
struct DictationPreferencesTests {
    private func withStoredValue(_ value: Any?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let key = DictationPreferences.onDeviceOnlyKey
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        body()
    }

    @Test func keyAndDefault() {
        #expect(DictationPreferences.onDeviceOnlyKey == "pincer.dictation.onDeviceOnly")
        #expect(DictationPreferences.onDeviceOnlyDefault == false)
    }

    @Test func unsetReadsTheDefault() {
        withStoredValue(nil) { #expect(DictationPreferences.onDeviceOnly == false) }
    }

    @Test func readsTheStoredValue() {
        withStoredValue(true) { #expect(DictationPreferences.onDeviceOnly) }
        withStoredValue(false) { #expect(!DictationPreferences.onDeviceOnly) }
    }

    @Test func onDeviceUnavailableNamesTheLanguage() {
        let issue = DictationIssue.onDeviceUnavailable(language: "Swahili")
        #expect(issue.message.contains("Swahili"))
        #expect(issue.message.contains("On-device"))
        #expect(!issue.canOpenSettings, "it's Pincer's own setting, not the system's")
        #expect(issue != .onDeviceUnavailable(language: "French"))
        #expect(DictationIssue.onDeviceUnavailable(language: "French").message.contains("French"))
    }
}
