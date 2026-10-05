#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Quick Capture send target ownership", .timeLimit(.minutes(2)))
struct QuickCaptureSendTargetOwnershipTests {
    actor Delivery {
        var entered = false, released = false
        var waiter: CheckedContinuation<Void, Never>?
        func hold(_ method: String) async {
            guard method == "chat.send" else { return }
            entered = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released { continuation.resume() } else { waiter = continuation }
                }
            } onCancel: { Task { await self.release() } }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    @Test(arguments: [0, 1, 2])
    func completedSendPreservesOnlyNewerPickedTarget(selectionChanges: Int) async throws {
        let scratch = ScratchDefaults()
        GatewayProfileStore.save([.demo()], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults, identity: Fixtures.identity())
        let gateway = try #require(app.gateways.first)
        #expect(app.deviceIdForDisplay == Fixtures.deviceId)
        let connectionIdentity = await gateway.connection.deviceId
        #expect(connectionIdentity == Fixtures.deviceId)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); scratch.remove() }
        gateway.start(); gateway.reconnectIfNeeded()
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !gateway.state.isConnected || !gateway.bootstrapped {
            try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        let model = QuickCaptureModel(app: app, defaults: scratch.defaults)
        let items = model.items
        let first = try #require(items.first { if case let .openChat(ref) = $0.action { return ref.sessionKey == "agent:main:main" }; return false })
        let next = try #require(items.first { if case let .openChat(ref) = $0.action { return ref.sessionKey == "agent:main:dashboard:trip" }; return false })
        #expect(model.pick(first))
        let nonce = "quick-target-" + UUID().uuidString
        model.text = nonce
        await gateway.connection.demoTrackSendRequests(matchingText: nonce)
        let delivery = Delivery()
        await gateway.connection.setDemoResponseDelivery { await delivery.hold($0) }
        let sending = Task { await model.send() }
        do {
            let admission = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await delivery.entered) {
                try Task.checkCancellation(); try #require(ContinuousClock.now < admission)
                try await Task.sleep(for: .milliseconds(10))
            }
            let actualRequests = await gateway.connection.demoSendRequests(matchingText: nonce)
            #expect(actualRequests.count == 1 && actualRequests.first?.idempotencyKey.isEmpty == false)
            #expect(model.isSending)
            if selectionChanges > 0 { #expect(model.pick(next)) }
            if selectionChanges == 2 { #expect(model.pick(first)) }
            let expected = selectionChanges == 0 ? nil : QuickCaptureTarget(item: selectionChanges == 2 ? first : next)
            await delivery.release()
            let accepted = await sending.value
            #expect(accepted && !model.isSending && model.error == nil && model.text.isEmpty)
            #expect(model.settings.lastTarget == QuickCaptureTarget(item: first))
            #expect(model.target == expected, "a completed prior send must preserve the actual newer pick")
        } catch {
            sending.cancel(); await delivery.release(); _ = await sending.value
            await gateway.connection.setDemoResponseDelivery(nil)
            await gateway.connection.demoUntrackSendRequests(matchingText: nonce)
            throw error
        }
        await gateway.connection.setDemoResponseDelivery(nil)
        await gateway.connection.demoUntrackSendRequests(matchingText: nonce)
    }
}
#endif
