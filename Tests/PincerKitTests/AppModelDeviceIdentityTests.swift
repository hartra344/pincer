import Testing
@testable import PincerKit

@MainActor
@Suite("App managed device identity", .serialized)
struct AppModelDeviceIdentityTests {
    @Test func firstAndLaterGatewaysShareTheSameIdentity() {
        guard Keychain.isInMemory else {
            Issue.record("app identity lifecycle tests must use the in-memory Keychain")
            return
        }
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        defer { for gateway in app.gateways { app.remove(gateway.id) } }

        let first = app.add(.demo(), secret: nil)
        let firstDeviceId = first.deviceId
        let second = app.add(.demo(), secret: nil)

        #expect(!firstDeviceId.isEmpty)
        #expect(second.deviceId == firstDeviceId,
                "the first and subsequent app-managed Gateways use one paired device identity")
        #expect(DeviceIdentity.loadExisting()?.deviceId == firstDeviceId,
                "AppModel's first Gateway caches the identity saved in Keychain")

        app.update(first.profile, secret: nil, credentialsChanged: false)
        let replacement = app.gateways.first { $0.id == first.id }
        #expect(replacement?.deviceId == firstDeviceId,
                "replacing a Gateway preserves the app's device identity")
    }
}
