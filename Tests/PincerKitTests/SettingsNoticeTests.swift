import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2)))
struct SettingsNoticeTests {
    @Test func defaultsToInfoWithUniqueIdentity() {
        let a = SettingsNotice(text: "Saved")
        let b = SettingsNotice(text: "Saved")
        #expect(a.severity == .info)
        #expect(a.id != b.id)
        #expect(a == a)
    }

    @Test func modelsShareTheNoticeType() {
        #expect(DeviceManagementModel.Notice.self == SettingsNotice.self)
        #expect(PairingInboxModel.Notice.self == SettingsNotice.self)
    }
}
