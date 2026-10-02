import PincerKit

/// Native window tests own notification delivery and layout; these check the consumed shared cap.
@MainActor
func checkSettingsContentHeight() {
    check(SettingsContentHeight.limit(visibleScreenHeight: 600) == 460,
          "settings height: shorter display reserves room for window chrome")
    check(SettingsContentHeight.limit(visibleScreenHeight: 900) == 720,
          "settings height: returning to a larger display restores the comfortable cap")
    check(SettingsContentHeight.limit(visibleScreenHeight: nil) == 720,
          "settings height: a missing display uses the existing fallback")
    check(SettingsContentHeight.limit(visibleScreenHeight: 300) == 240,
          "settings height: very short displays retain the existing content minimum")
}
