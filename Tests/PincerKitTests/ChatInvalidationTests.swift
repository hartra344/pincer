import Foundation
import Observation
import Testing
@testable import PincerKit

/// Counts observation fires; onChange runs synchronously on the writer's thread.
final class Fires: @unchecked Sendable {
    private(set) var count = 0
    func bump() { self.count += 1 }
    func reset() { self.count = 0 }
}

@MainActor
@Suite("Chat invalidation")
struct ChatInvalidationTests {
    let scratch = ScratchDefaults()
    let profile = GatewayProfile(name: "Test", url: "ws://127.0.0.1:1", authMode: .none)
    static let key = "agent:main:dashboard:a"
    static let other = "agent:main:dashboard:b"

    func snapshot(active: Set<String> = [], other otherLabel: String = "B") -> JSONValue {
        Fixtures.json("""
        {"sessions":[
          {"key":"\(Self.key)","label":"A","updatedAt":100,"hasActiveRun":\(active.contains(Self.key))},
          {"key":"\(Self.other)","label":"\(otherLabel)","updatedAt":200,"hasActiveRun":\(active.contains(Self.other))}
        ]}
        """)
    }

    func setup() -> (GatewayStore, ChatStore) {
        let gateway = GatewayStore(profile: self.profile, defaults: self.scratch.defaults, identity: Fixtures.identity())
        gateway.applySnapshot(self.snapshot())
        return (gateway, gateway.chat(for: Self.key))
    }

    func delta(_ chat: ChatStore, _ text: String) {
        chat.handleChat(["runId": "r1", "sessionKey": .string(Self.key), "state": "delta", "deltaText": .string(text)])
    }

    @Test func isRunningFiresOnlyOnTransitions() {
        defer { self.scratch.remove() }
        let (_, chat) = self.setup()
        let fired = Fires()
        withObservationTracking { _ = chat.isRunning } onChange: { fired.bump() }
        self.delta(chat, "a")
        #expect(chat.isRunning)
        #expect(fired.count == 1)
        // Re-arm: further deltas must not touch isRunning.
        fired.reset()
        withObservationTracking { _ = chat.isRunning } onChange: { fired.bump() }
        for i in 0..<200 { self.delta(chat, "tok\(i) ") }
        #expect(fired.count == 0)
    }

    @Test func sessionsRowFlipTogglesIsRunning() {
        defer { self.scratch.remove() }
        let (gateway, chat) = self.setup()
        #expect(!chat.isRunning)
        let fired = Fires()
        withObservationTracking { _ = chat.isRunning } onChange: { fired.bump() }
        gateway.applySnapshot(self.snapshot(active: [Self.key]))
        #expect(fired.count == 1 && chat.isRunning)
        gateway.applySnapshot(self.snapshot())
        #expect(!chat.isRunning)
    }

    @Test func otherSessionChangeDoesNotInvalidateSessionRow() {
        defer { self.scratch.remove() }
        let (gateway, chat) = self.setup()
        let fired = Fires()
        withObservationTracking { _ = chat.sessionRow } onChange: { fired.bump() }
        gateway.applySnapshot(self.snapshot(other: "B renamed"))
        #expect(fired.count == 0)
        #expect(chat.sessionRow?.title == "A")
    }

    @Test func ownSessionChangeInvalidatesSessionRow() {
        defer { self.scratch.remove() }
        let (gateway, chat) = self.setup()
        let fired = Fires()
        withObservationTracking { _ = chat.sessionRow } onChange: { fired.bump() }
        gateway.applySnapshot(self.snapshot(active: [Self.key]))
        #expect(fired.count == 1)
        #expect(chat.sessionRow == gateway.sessions[Self.key])
    }
}
