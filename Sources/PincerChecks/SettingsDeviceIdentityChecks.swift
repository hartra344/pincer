import Foundation
import PincerKit

@MainActor
func runSettingsDeviceIdentityChecks() {
    Keychain.withIsolatedMemoryStore {
        let (defaults, suite) = scratchDefaults()
        let app = AppModel(defaults: defaults)
        defer {
            for gateway in app.gateways { app.remove(gateway.id) }
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        let emptySuite = "pincer-checks-device-id-empty-\(UUID())"
        let emptyDefaults = UserDefaults(suiteName: emptySuite)!
        let emptyApp = AppModel(defaults: emptyDefaults)
        defer { emptyDefaults.removePersistentDomain(forName: emptySuite) }
        check(emptyApp.deviceIdForDisplay == nil,
              "an empty AppModel leaves its display identity unset without loading Keychain")
        let first = app.add(.demo(), secret: nil)
        let firstDeviceId = first.deviceId
        check(app.deviceIdForDisplay == firstDeviceId,
              "the first app-managed Gateway publishes its cached device ID for Settings")
        check(emptyApp.deviceIdForDisplay == nil,
              "reading an uncached display ID does not load identity from Keychain")
        let later = app.add(.demo(), secret: nil)
        check(!firstDeviceId.isEmpty && later.deviceId == firstDeviceId,
              "first and later AppModel Gateways use the same device identity")
        check(app.deviceIdForDisplay == firstDeviceId,
              "adding another Gateway leaves the display identity unchanged")

        let restored = AppModel(defaults: defaults)
        check(restored.deviceIdForDisplay == firstDeviceId,
              "saved Gateway profiles restore the existing identity into the Settings cache")
    }
}
