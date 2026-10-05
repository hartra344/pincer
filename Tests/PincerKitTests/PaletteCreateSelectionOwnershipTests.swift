#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor @Suite(.timeLimit(.minutes(2)))
struct PaletteCreateSelectionOwnershipTests {
    actor Delivery {
        var entered = false, released = false
        var waiter: CheckedContinuation<Void, Never>?
        func hold(_ method: String) async {
            guard method == "sessions.create" else { return }
            entered = true
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released { continuation.resume() } else { waiter = continuation }
                }
            } onCancel: { Task { await self.release() } }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func actualPaletteCreateCannotReplaceNewerMainSelection(change: Int) async throws {
        try await exercise(change: change, palette: true)
    }
    @Test(arguments: [0, 1, 3])
    func actualGatewayCreateCannotReplaceNewerChatSelection(change: Int) async throws {
        try await exercise(change: change, palette: false)
    }

    private func exercise(change: Int, palette: Bool) async throws {
        let scratch = ScratchDefaults()
        GatewayProfileStore.save([.demo(), .demo()], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults, identity: Fixtures.identity())
        let gateway = try #require(app.gateways.first)
        let other = try #require(app.gateways.last)
        #expect(gateway.id != other.id)
        for store in app.gateways { store.cacheRoot = nil; store.outboxRoot = nil; store.notifier = nil; store.start(); store.reconnectIfNeeded() }
        defer { app.gateways.forEach { $0.stop() }; scratch.remove() }
        let readiness = ContinuousClock.now.advanced(by: .seconds(25))
        while !app.gateways.allSatisfy({ $0.state.isConnected && $0.bootstrapped }) {
            try Task.checkCancellation(); try #require(ContinuousClock.now < readiness)
            try await Task.sleep(for: .milliseconds(10))
        }
        // Use real seeded chat keys rather than relying on an invented session.
        let first = try #require(gateway.sortedRows.first?.key)
        let second = try #require(gateway.sortedRows.first(where: { $0.key != first })?.key)
        let otherKey = try #require(other.sortedRows.first?.key)
        app.open(Notifier.Target(gatewayId: gateway.id, sessionKey: first))
        if change == 4 { app.open(Notifier.Target(gatewayId: other.id, sessionKey: otherKey)) }
        let before = Set(gateway.sessions.keys)
        let delivery = Delivery()
        await gateway.connection.setDemoResponseDelivery { await delivery.hold($0) }
        let action = Task {
            if palette { return await app.createPaletteChat(gateway: gateway, agentId: "research") }
            return await gateway.createSession(agentId: "research", label: nil)
        }
        do {
            let admission = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await delivery.entered) {
                try Task.checkCancellation(); try #require(ContinuousClock.now < admission)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(gateway.selectedKey == first && app.selectedGatewayId == (change == 4 ? other.id : gateway.id))
            if change == 1 || change == 3 {
                app.open(Notifier.Target(gatewayId: gateway.id, sessionKey: second))
                if change == 3 { app.open(Notifier.Target(gatewayId: gateway.id, sessionKey: first)) }
            } else if change == 2 {
                app.open(Notifier.Target(gatewayId: other.id, sessionKey: otherKey))
            }
            let expectedKey = gateway.selectedKey, expectedGateway = app.selectedGatewayId
            let opensBeforeCompletion = app.openRequests
            await delivery.release()
            let result = await action.value
            let created = try #require(result)
            #expect(created.hasPrefix("agent:research:") && gateway.sessions[created]?.key == created)
            #expect(Set(gateway.sessions.keys).subtracting(before) == [created])
            if change == 0 || change == 4 {
                #expect(gateway.selectedKey == created && app.selectedGatewayId == gateway.id)
                #expect(app.openRequests == opensBeforeCompletion + (palette ? 1 : 0))
            } else {
                #expect(gateway.selectedKey == expectedKey && app.selectedGatewayId == expectedGateway,
                        "completed actual creation must retain newer selection intent, including ABA")
                #expect(app.openRequests == opensBeforeCompletion,
                        "the actual palette completion must not open over a newer choice")
            }
        } catch {
            action.cancel(); await delivery.release(); _ = await action.value
            await gateway.connection.setDemoResponseDelivery(nil)
            throw error
        }
        await gateway.connection.setDemoResponseDelivery(nil)
    }
}
#endif
