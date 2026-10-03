import Foundation
import Testing
@testable import PincerKit

@Suite("Location transport selection retention")
struct LocationSelectionRetentionTests {
    @Test @MainActor func lateDefaultSelectionReleasesColdChatButRecentSelectionKeepsItWarm() async {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }

        let profile = GatewayProfile(name: "Offline selection fixture", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.outboxRoot = nil

        let mainKey = "agent:main:main"
        let observedKey = "agent:main:location-observer"
        let main = gateway.chat(for: mainKey)
        let observed = gateway.chat(for: observedKey)
        for chat in [main, observed] {
            // Selection opens a chat asynchronously. These flags keep this policy test offline
            // and prevent restoreDraft/restoreFromCache from touching Application Support.
            chat.draftChecked = true
            chat.cacheChecked = true
        }

        observed.hasLoaded = true
        observed.stale = false
        observed.subscribedEpoch = gateway.connectionEpoch
        gateway.selectedKey = mainKey

        let retired = await self.waitFor(1) { observed.stale && !observed.isSubscribed }
        #expect(retired)
        #expect(!gateway.warmKeys(includingLive: true).contains(observedKey))

        // Re-open it, then let the default Main selection arrive. Its recent selection keeps
        // the observer warm even after Main becomes the selected chat again.
        observed.stale = false
        observed.subscribedEpoch = gateway.connectionEpoch
        gateway.selectedKey = observedKey
        gateway.selectedKey = mainKey
        // Give any retirement task the same opportunity to run as in the cold-chat case.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(gateway.warmKeys(includingLive: true).contains(observedKey))
        #expect(observed.isSubscribed && !observed.stale)
        gateway.stop()
    }

    @MainActor
    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
