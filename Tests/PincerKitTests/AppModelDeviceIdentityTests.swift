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
        Keychain.withIsolatedMemoryStore {
            let scratch = ScratchDefaults()
            defer { scratch.remove() }
            let emptyScratch = ScratchDefaults()
            defer { emptyScratch.remove() }
            let app = AppModel(defaults: scratch.defaults)
            let emptyApp = AppModel(defaults: emptyScratch.defaults)
            #expect(app.deviceIdForDisplay == nil,
                    "an empty AppModel does not create or display an identity before its first Gateway")
            defer { for gateway in app.gateways { app.remove(gateway.id) } }

            let first = app.add(.demo(), secret: nil)
            let firstDeviceId = first.deviceId
            #expect(app.deviceIdForDisplay == firstDeviceId)
            let readsAfterFirstGateway = Keychain.isolatedDeviceIdentityReadCount
            #expect(emptyApp.deviceIdForDisplay == nil,
                    "reading an uncached display ID does not load the identity from Keychain")
            let second = app.add(.demo(), secret: nil)

            #expect(!firstDeviceId.isEmpty)
            #expect(second.deviceId == firstDeviceId,
                    "the first and subsequent app-managed Gateways use one paired device identity")
            #expect(app.deviceIdForDisplay == firstDeviceId)
            #expect(Keychain.isolatedDeviceIdentityReadCount == readsAfterFirstGateway,
                    "subsequent Gateway creation reuses the app's cached identity")

            app.update(first.profile, secret: nil, credentialsChanged: false)
            let replacement = app.gateways.first { $0.id == first.id }
            #expect(replacement?.deviceId == firstDeviceId,
                    "replacing a Gateway preserves the app's device identity")
            #expect(app.deviceIdForDisplay == firstDeviceId)

            let restored = AppModel(defaults: scratch.defaults)
            #expect(restored.deviceIdForDisplay == firstDeviceId,
                    "saved Gateway profiles initialize the display cache from their shared identity")
        }
    }
}
