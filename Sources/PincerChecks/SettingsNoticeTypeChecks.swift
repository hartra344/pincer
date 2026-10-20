import Foundation
import PincerKit

@MainActor
func checkSettingsNotice() {
    let a = SettingsNotice(text: "Saved")
    let b = SettingsNotice(text: "Saved")
    check(a.severity == .info && a.id != b.id, "settings notice defaults to info with unique identity")
    check(DeviceManagementModel.Notice.self == SettingsNotice.self && PairingInboxModel.Notice.self == SettingsNotice.self,
          "device and pairing models share the settings notice type")
}
