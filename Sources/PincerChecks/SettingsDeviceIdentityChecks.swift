import Foundation
import PincerKit

@MainActor
func runSettingsDeviceIdentityChecks() {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    let first = app.add(.demo(), secret: nil)
    let firstDeviceId = first.deviceId
    let later = app.add(.demo(), secret: nil)
    check(!firstDeviceId.isEmpty && later.deviceId == firstDeviceId,
          "first and later AppModel Gateways use the same device identity")
}
