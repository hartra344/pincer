import Foundation
import Testing
@testable import PincerKit

/// `swift test` must never touch or prompt for the real Keychain, even without `PINCER_KEYCHAIN`.
@Suite("Keychain isolation")
struct KeychainIsolationTests {
    @Test func testRunnerUsesMemoryStore() {
        #expect(Keychain.isInMemory)
    }

    @Test func secretsRoundTripWithoutSecItemCalls() {
        let profile = GatewayProfile(name: "t", url: "ws://127.0.0.1:18870", authMode: .token)
        profile.secret = "s3cret"
        profile.deviceToken = "device-tok"
        #expect(profile.secret == "s3cret")
        #expect(profile.deviceToken == "device-tok")
        profile.secret = nil
        profile.forgetDeviceToken()
        #expect(profile.secret == nil)
        #expect(profile.deviceToken == nil)
        #expect(DeviceIdentity.loadOrCreate().deviceId == DeviceIdentity.loadOrCreate().deviceId)
        #expect(Keychain.realKeychainCalls == 0)
    }
}
