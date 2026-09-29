import Foundation
import Testing
@testable import PincerKit

@Suite("CoalescingEventBuffer")
struct EventBufferTests {
    private struct Item: Sendable, Equatable {
        var key: String?
        var value: Int
    }

    private func makeBuffer() -> CoalescingEventBuffer<Item> {
        CoalescingEventBuffer<Item> { $0.key }
    }

    private func drain(_ buffer: CoalescingEventBuffer<Item>) async -> [Item] {
        buffer.finish()
        var out: [Item] = []
        for await item in buffer { out.append(item) }
        return out
    }

    @Test func coalescesOnlyTheTail() async {
        let buffer = makeBuffer()
        buffer.yield(Item(key: "a", value: 1))
        buffer.yield(Item(key: "a", value: 2))
        buffer.yield(Item(key: "a", value: 3))
        #expect(buffer.pendingCount == 1 && buffer.coalescedCount == 2)
        #expect(await drain(buffer) == [Item(key: "a", value: 3)])
    }

    @Test func aKeyedEventBehindAnotherEventIsNotMerged() async {
        let buffer = makeBuffer()
        buffer.yield(Item(key: "a", value: 1))
        buffer.yield(Item(key: nil, value: 2))
        buffer.yield(Item(key: "a", value: 3))
        buffer.yield(Item(key: "b", value: 4))
        buffer.yield(Item(key: "a", value: 5))
        #expect(buffer.coalescedCount == 0)
        #expect(await drain(buffer).map(\.value) == [1, 2, 3, 4, 5])
    }

    @Test func nilKeyEventsAreNeverDropped() async {
        let buffer = makeBuffer()
        for value in 0..<50 { buffer.yield(Item(key: nil, value: value)) }
        #expect(buffer.pendingCount == 50 && buffer.coalescedCount == 0)
        #expect(await drain(buffer).map(\.value) == Array(0..<50))
    }

    @Test func orderIsKeptAcrossMixedEvents() async {
        let buffer = makeBuffer()
        buffer.yield(Item(key: "x", value: 1))
        buffer.yield(Item(key: "x", value: 2))
        buffer.yield(Item(key: nil, value: 3))
        buffer.yield(Item(key: nil, value: 4))
        buffer.yield(Item(key: "x", value: 5))
        buffer.yield(Item(key: "x", value: 6))
        #expect(await drain(buffer).map(\.value) == [2, 3, 4, 6])
    }

    @Test func aWaitingConsumerGetsEveryEvent() async {
        let buffer = makeBuffer()
        let consumer = Task { () -> [Int] in
            var seen: [Int] = []
            for await item in buffer { seen.append(item.value) }
            return seen
        }
        for value in 0..<20 {
            buffer.yield(Item(key: nil, value: value))
            await Task.yield()
        }
        buffer.finish()
        #expect(await consumer.value == Array(0..<20))
    }

    @Test func yieldAfterFinishIsIgnoredAndCancellationEndsTheStream() async {
        let buffer = makeBuffer()
        buffer.finish()
        buffer.yield(Item(key: nil, value: 1))
        #expect(buffer.pendingCount == 0)

        let open = makeBuffer()
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in open { count += 1 }
            return count
        }
        await Task.yield()
        consumer.cancel()
        #expect(await consumer.value == 0)
    }
}

@Suite("GatewayEvent coalescing key")
struct GatewayEventCoalescingKeyTests {
    private func event(_ name: String, _ payload: JSONValue) -> GatewayEvent {
        GatewayEvent(name: name, payload: payload, seq: nil)
    }

    @Test func cumulativeChatSnapshotsShareAKeyPerRun() {
        let a = event("chat", ["state": "delta", "runId": "r1", "sessionKey": "s", "message": ["role": "assistant"]])
        let b = event("chat", ["state": "delta", "runId": "r1", "sessionKey": "s", "message": ["role": "assistant"]])
        let other = event("chat", ["state": "delta", "runId": "r2", "sessionKey": "s", "message": ["role": "assistant"]])
        #expect(a.coalescingKey != nil && a.coalescingKey == b.coalescingKey && a.coalescingKey != other.coalescingKey)
        let replace = event("chat", ["state": "delta", "runId": "r1", "sessionKey": "s", "deltaText": "hi", "replace": true])
        #expect(replace.coalescingKey == a.coalescingKey)
    }

    @Test func incrementalAndTerminalEventsNeverCoalesce() {
        #expect(event("chat", ["state": "delta", "runId": "r1", "sessionKey": "s", "deltaText": "hi"]).coalescingKey == nil)
        #expect(event("chat", ["state": "final", "runId": "r1", "sessionKey": "s", "message": ["role": "assistant"]]).coalescingKey == nil)
        #expect(event("chat", ["state": "aborted", "runId": "r1", "sessionKey": "s"]).coalescingKey == nil)
        #expect(event("agent", ["runId": "r1", "stream": "lifecycle", "data": ["phase": "end"]]).coalescingKey == nil)
        #expect(event("sessions.changed", ["reason": "groups"]).coalescingKey == nil)
        #expect(event("exec.approval.requested", ["id": "a"]).coalescingKey == nil)
    }
}
