#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite("Quick Capture created target ownership", .timeLimit(.minutes(2)))
struct QuickCaptureCreatedTargetOwnershipTests {
    actor Delivery {
        var createEntered = false, sendEntered = false
        var createReleased = false, sendReleased = false
        var createWaiter: CheckedContinuation<Void, Never>?, sendWaiter: CheckedContinuation<Void, Never>?
        func hold(_ method: String) async {
            guard method == "sessions.create" || method == "chat.send" else { return }
            let creation = method == "sessions.create"
            if creation { createEntered = true } else { sendEntered = true }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if creation {
                        if createReleased { continuation.resume() } else { createWaiter = continuation }
                    } else {
                        if sendReleased { continuation.resume() } else { sendWaiter = continuation }
                    }
                }
            } onCancel: { Task { await self.releaseAll() } }
        }
        func releaseCreate() { createReleased = true; createWaiter?.resume(); createWaiter = nil }
        func releaseAll() { releaseCreate(); sendReleased = true; sendWaiter?.resume(); sendWaiter = nil }
    }

    @Test(arguments: [false, true])
    func actualCreateThenSendPreservesOnlyNewerPick(changeTarget: Bool) async throws {
        let scratch = ScratchDefaults()
        GatewayProfileStore.save([.demo()], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults, identity: Fixtures.identity())
        let gateway = try #require(app.gateways.first)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); scratch.remove() }
        gateway.start(); gateway.reconnectIfNeeded()
        let bootstrap = ContinuousClock.now.advanced(by: .seconds(25))
        while !gateway.state.isConnected || !gateway.bootstrapped {
            try Task.checkCancellation(); try #require(ContinuousClock.now < bootstrap)
            try await Task.sleep(for: .milliseconds(10))
        }
        let model = QuickCaptureModel(app: app, defaults: scratch.defaults)
        let items = model.items
        let creation = try #require(items.first { if case let .newChat(_, agentId) = $0.action { return agentId == "research" }; return false })
        let next = try #require(items.first { if case let .openChat(ref) = $0.action { return ref.sessionKey == "agent:main:dashboard:trip" }; return false })
        #expect(model.pick(creation))
        let before = Set(gateway.sessions.keys)
        let nonce = "quick-create-target-" + UUID().uuidString
        model.text = nonce
        await gateway.connection.demoTrackSendRequests(matchingText: nonce)
        let delivery = Delivery()
        await gateway.connection.setDemoResponseDelivery { await delivery.hold($0) }
        let sending = Task { await model.send() }
        do {
            let admission = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await delivery.createEntered) {
                try Task.checkCancellation(); try #require(ContinuousClock.now < admission)
                try await Task.sleep(for: .milliseconds(10))
            }
            let preSend = await gateway.connection.demoSendRequests(matchingText: nonce)
            #expect(preSend.isEmpty && model.isSending)
            if changeTarget { #expect(model.pick(next)) }
            await delivery.releaseCreate()
            let sendAdmission = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await delivery.sendEntered) || Set(gateway.sessions.keys).subtracting(before).isEmpty {
                try Task.checkCancellation(); try #require(ContinuousClock.now < sendAdmission)
                try await Task.sleep(for: .milliseconds(10))
            }
            let createdKeys = Set(gateway.sessions.keys).subtracting(before)
            #expect(createdKeys.count == 1)
            let created = try #require(createdKeys.first)
            #expect(created.hasPrefix("agent:research:"))
            let actualRequests = await gateway.connection.demoSendRequests(matchingText: nonce)
            #expect(actualRequests.count == 1 && actualRequests.first?.idempotencyKey.isEmpty == false)
            let createdTarget = QuickCaptureTarget(gatewayId: gateway.id, target: .chat(created))
            #expect(model.target == (changeTarget ? QuickCaptureTarget(item: next) : createdTarget),
                    "actual create completion must not replace a newer target while its send is held")
            await delivery.releaseAll()
            let accepted = await sending.value
            #expect(accepted && !model.isSending && model.error == nil && model.text.isEmpty)
            #expect(model.settings.lastTarget == createdTarget)
            #expect(model.target == (changeTarget ? QuickCaptureTarget(item: next) : nil),
                    "actual send completion must preserve the newer pick")
        } catch {
            sending.cancel(); await delivery.releaseAll(); _ = await sending.value
            await gateway.connection.setDemoResponseDelivery(nil)
            await gateway.connection.demoUntrackSendRequests(matchingText: nonce)
            throw error
        }
        await gateway.connection.setDemoResponseDelivery(nil)
        await gateway.connection.demoUntrackSendRequests(matchingText: nonce)
    }
}
#endif
