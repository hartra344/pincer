import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Push registrar defaults")
struct PushRegistrarDefaultsTests {
    @Test func registrarsWithSeparateSuitesDoNotShareState() {
        let nameA = "pincer-tests-\(UUID())", nameB = "pincer-tests-\(UUID())"
        let a = UserDefaults(suiteName: nameA)!, b = UserDefaults(suiteName: nameB)!
        defer {
            a.removePersistentDomain(forName: nameA)
            b.removePersistentDomain(forName: nameB)
        }
        a.set("https://relay-a.example.com", forKey: PushRegistrar.relayKey)
        a.set("https://endpoint-a", forKey: "pincer.push.endpoint.x")
        a.set(["key": "k", "id": "relay-a"], forKey: "pincer.push.relayId")
        a.set(false, forKey: "pincer.notifications")

        let regA = PushRegistrar(defaults: a), regB = PushRegistrar(defaults: b)
        if ProcessInfo.processInfo.environment["PINCER_PUSH_RELAY"] == nil {
            #expect(regA.relayURL?.host == "relay-a.example.com")
            #expect(regB.relayURL == nil)
        }
        #expect(!regA.notificationsEnabled())
        #expect(!regB.notificationsEnabled())
        ClosedAppDelivery.set(.pushRelay, b)
        #expect(regB.notificationsEnabled())
        #expect(b.string(forKey: "pincer.push.endpoint.x") == nil)
        #expect(b.dictionary(forKey: "pincer.push.relayId") == nil)
    }
}
