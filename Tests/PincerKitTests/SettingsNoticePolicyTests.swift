import Testing
@testable import PincerKit

@Suite("Settings notice lifetime")
struct SettingsNoticePolicyTests {
    @Test func onlyInformationalResultsAutoDismiss() {
        #expect(SettingsNoticePolicy.shouldAutoDismiss(.success))
        #expect(SettingsNoticePolicy.shouldAutoDismiss(.info))
        #expect(!SettingsNoticePolicy.shouldAutoDismiss(.warning), "warnings need time to read")
        #expect(!SettingsNoticePolicy.shouldAutoDismiss(.error), "errors stay until explicitly dismissed")
    }
}
