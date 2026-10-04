import Foundation
import Testing
@testable import PincerKit

/// Holds an already computed transport result; cancellation releases owned continuations.
@MainActor private final class ChannelActionDeliveryGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var delivery: CheckedContinuation<Void, Never>?

    func hold() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                entered = true
                entryWaiter?.resume()
                entryWaiter = nil
                if released || Task.isCancelled { continuation.resume() }
                else { delivery = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
    }

    func waitForEntry() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if entered || Task.isCancelled { continuation.resume() }
                else { entryWaiter = continuation }
            }
        } onCancel: { Task { @MainActor in self.release() } }
        try Task.checkCancellation()
    }

    func release() {
        released = true
        entryWaiter?.resume(); entryWaiter = nil
        delivery?.resume(); delivery = nil
    }
}

@Suite(.timeLimit(.minutes(2))) @MainActor
struct ChannelActionCompletionOwnershipTests {
    @Test(arguments: [false, true])
    func clearedLifecycleCannotResurrectOldFailure(reset: Bool) async throws {
        let gate = ChannelActionDeliveryGate()
        let key = ChannelAccountKey(channel: "telegram", accountId: "default")
        let model = ChannelsModel(scopes: { [GatewayConnection.adminScope] }) { method, params in
            if method == "channels.stop" {
                #expect(params == ["channel": "telegram", "accountId": "default"])
                await gate.hold()
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "held local transport failure", details: nil)
            }
            return ChannelFixtures.status
        }
        let old = Task { await model.stop(key) }
        defer { gate.release(); old.cancel() }
        try await gate.waitForEntry()
        #expect(model.isBusy(key))
        if reset { model.reset() } else { model.disconnected() }
        #expect(model.operation(for: key) == nil)
        gate.release()
        _ = await old.value
        #expect(model.operation(for: key) == nil)
        #expect(model.notice == nil)
    }

    @Test(arguments: [false, true])
    func oldCompletionCannotReplaceNewSameAccountAction(oldFails: Bool) async throws {
        let first = ChannelActionDeliveryGate()
        let second = ChannelActionDeliveryGate()
        let key = ChannelAccountKey(channel: "telegram", accountId: "default")
        var calls = 0
        let model = ChannelsModel(scopes: { [GatewayConnection.adminScope] }) { method, _ in
            guard method == "channels.stop" else { return ChannelFixtures.status }
            calls += 1
            let number = calls
            if number == 1 { await first.hold() } else { await second.hold() }
            if number == 1 && oldFails {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "old transport error", details: nil)
            }
            return ["channel": "telegram", "accountId": "default", "stopped": true]
        }
        let old = Task { await model.stop(key) }
        defer { first.release(); second.release(); old.cancel() }
        try await first.waitForEntry()
        model.disconnected()
        let current = Task { await model.stop(key) }
        defer { current.cancel() }
        try await second.waitForEntry()
        #expect(calls == 2)
        first.release()
        _ = await old.value
        #expect(model.isBusy(key))
        #expect(model.notice == nil)
        second.release()
        #expect(await current.value)
        #expect(model.operation(for: key) == nil)
        #expect(model.notice?.isError == false)
    }

    @Test func ordinaryAndDifferentAccountCompletionRemainIndependent() async throws {
        let gate = ChannelActionDeliveryGate()
        let heldKey = ChannelAccountKey(channel: "telegram", accountId: "default")
        let otherKey = ChannelAccountKey(channel: "discord", accountId: "default")
        let model = ChannelsModel(scopes: { [GatewayConnection.adminScope] }) { method, params in
            guard method == "channels.stop" else { return ChannelFixtures.status }
            if params["channel"]?.string == "telegram" { await gate.hold() }
            return ["channel": params["channel"] ?? .null, "accountId": "default", "stopped": true]
        }
        let held = Task { await model.stop(heldKey) }
        defer { gate.release(); held.cancel() }
        try await gate.waitForEntry()
        #expect(await model.stop(otherKey))
        #expect(model.isBusy(heldKey))
        #expect(model.operation(for: otherKey) == nil)
        gate.release()
        #expect(await held.value)
        #expect(model.operation(for: heldKey) == nil)
        #expect(model.notice?.isError == false)
    }
}

extension ChannelActionCompletionOwnershipTests {
    @Test func currentUnsupportedFailureRemainsVisible() async {
        let key = ChannelAccountKey(channel: "telegram", accountId: "default")
        let model = ChannelsModel(scopes: { [GatewayConnection.adminScope] }) { _, _ in
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "channel telegram does not support start", details: nil)
        }
        #expect(await model.start(key) == false)
        #expect(model.operation(for: key)?.state.error != nil)
        #expect(model.notice?.isError == true)
        #expect(model.isUnsupported(.start, channel: "telegram"))
    }

    @Test func canceledActionDoesNotPublishComputedResponse() async throws {
        let gate = ChannelActionDeliveryGate()
        let key = ChannelAccountKey(channel: "telegram", accountId: "default")
        let model = ChannelsModel(scopes: { [GatewayConnection.adminScope] }) { method, _ in
            if method == "channels.stop" { await gate.hold() }
            return ["channel": "telegram", "accountId": "default", "stopped": true]
        }
        let action = Task { await model.stop(key) }
        defer { gate.release(); action.cancel() }
        try await gate.waitForEntry()
        action.cancel()
        gate.release()
        #expect(await action.value == false)
        #expect(model.operation(for: key) == nil)
        #expect(model.notice == nil)
    }
}
