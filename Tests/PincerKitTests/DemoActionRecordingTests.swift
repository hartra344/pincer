import Testing
@testable import PincerKit

@Suite(.timeLimit(.minutes(2))) struct DemoActionRecordingTests {
    @Test func acceptedActionsRetainExactOrderAndReplayDoesNotAppend() async throws {
        let demo = DemoGateway()
        let add: JSONValue = ["channel": "discord", "action": "react", "idempotencyKey": "record-add",
            "params": ["messageId": "owned-message", "emoji": "🎉", "remove": false]]
        let remove: JSONValue = ["channel": "discord", "action": "react", "idempotencyKey": "record-remove",
            "params": ["messageId": "owned-message", "emoji": "🎉", "remove": true]]
        let first = try await demo.handle("message.action", add)
        let duplicate = try await demo.handle("message.action", add)
        let second = try await demo.handle("message.action", remove)
        #expect(first == duplicate && first == ["ok": true, "added": "🎉"])
        #expect(second == ["ok": true, "removed": "🎉"])
        let recorded = await demo.recordedActions
        #expect(recorded == [add, remove])
        do {
            _ = try await demo.handle("message.action", ["channel": "discord", "action": "unsupported", "idempotencyKey": "bad", "params": [:]])
            Issue.record("Unsupported action must fail")
        } catch {
            let after = await demo.recordedActions
            #expect(after == recorded)
        }
    }
}
