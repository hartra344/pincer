import PincerKit

@MainActor
func runSettingsNoticeChecks() {
    check(SettingsNoticePolicy.shouldAutoDismiss(.success), "settings notices: success results can expire")
    check(SettingsNoticePolicy.shouldAutoDismiss(.info), "settings notices: informational results can expire")
    check(!SettingsNoticePolicy.shouldAutoDismiss(.warning), "settings notices: warnings wait for explicit dismissal")
    check(!SettingsNoticePolicy.shouldAutoDismiss(.error), "settings notices: errors wait for explicit dismissal")
}
