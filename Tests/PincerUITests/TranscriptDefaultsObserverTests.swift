import Dispatch
import Foundation
@testable import PincerKit
import Testing
@testable import PincerUI

/// A transcript watches every defaults change. Its observer must not make a write on another thread
/// wait for main: that stalled CI's unit run for over a minute (#920).
@MainActor
@Suite("Transcript defaults observer")
struct TranscriptDefaultsObserverTests {
    @Test func backgroundDefaultsWriteDoesNotWaitForMain() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let gateway = GatewayStore(profile: GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: UIFixtures.identity())
        let key = "agent:t:main"
        let context = TranscriptContext(gateway: gateway, disclosure: TranscriptDisclosure(),
                                        agent: AgentSummary(id: "t", name: "T"), sessionKey: key,
                                        previewImage: { _ in }, saveFile: { _, _ in }, chat: gateway.chat(for: key))
        let renderer = TranscriptRenderer(context: context)
        let written = DispatchSemaphore(value: 0)
        let defaults = UncheckedSendableBox(scratch.defaults)
        DispatchQueue.global().async {
            defaults.value.set(UUID().uuidString, forKey: "transcript-observer-probe")
            written.signal()
        }
        // Main stays blocked here, so the write only returns if it doesn't wait for main.
        #expect(written.wait(timeout: .now() + 10) == .success)
        withExtendedLifetime(renderer) {}
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
