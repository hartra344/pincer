#if DEBUG
import Foundation
import Testing
@testable import PincerKit

// Official9151e48c4f9cf6c2a306535aa295e9a967518585 sessions.ts645–667 and
// sessions-rewind.ts124–126: actual sessions.fork persisted-user cut, no fallback fixture.
@MainActor @Suite(.timeLimit(.minutes(2)))
struct BranchSelectionOwnershipTests {
    actor Delivery {
        var entered = false, released = false
        var waiter: CheckedContinuation<Void, Never>?
        func hold(_ method: String) async {
            guard method == "sessions.fork" else { return }
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
    func actualBranchPreservesNewerSelection(change: Int) async throws {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: .demo(), defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        defer { gateway.stop(); scratch.remove() }
        gateway.start(); gateway.reconnectIfNeeded()
        let ready = ContinuousClock.now.advanced(by: .seconds(25))
        while !gateway.state.isConnected || !gateway.bootstrapped {
            try Task.checkCancellation(); try #require(ContinuousClock.now < ready)
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(gateway.hello?.methods.contains("sessions.fork") == true)
        let sourceKey = "agent:main:dashboard:garden", otherKey = "agent:main:dashboard:trip"
        try #require(gateway.sessions[sourceKey] != nil && gateway.sessions[otherKey] != nil)
        let chat = gateway.chat(for: sourceKey)
        await chat.load()
        let user = try #require(chat.items.last { $0.role == .user && $0.isCommittedEntry && $0.transcriptId != nil })
        let text = user.plainText
        try #require(!text.isEmpty && chat.canBranch(from: user.id))
        gateway.selectedKey = sourceKey
        let before = Set(gateway.sessions.keys)
        let delivery = Delivery()
        await gateway.connection.setDemoResponseDelivery { await delivery.hold($0) }
        let action = Task { await chat.branch(from: user.id) }
        do {
            let admission = ContinuousClock.now.advanced(by: .seconds(15))
            while !(await delivery.entered) {
                try Task.checkCancellation(); try #require(ContinuousClock.now < admission)
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(gateway.selectedKey == sourceKey)
            if change > 0 { gateway.selectedKey = otherKey }
            if change == 2 { gateway.selectedKey = sourceKey }
            let expected = gateway.selectedKey
            await delivery.release()
            let result = await action.value
            let created = try #require(result)
            #expect(created != sourceKey && gateway.sessions[created]?.key == created)
            #expect(Set(gateway.sessions.keys).subtracting(before) == [created])
            #expect(gateway.chat(for: created).draft.text == text && chat.errorMessage == nil)
            #expect(gateway.selectedKey == (change == 0 ? created : expected), "actual fork completion must retain newer B or ABA selection")
        } catch {
            action.cancel(); await delivery.release(); _ = await action.value
            await gateway.connection.setDemoResponseDelivery(nil)
            throw error
        }
        await gateway.connection.setDemoResponseDelivery(nil)
    }
}
#endif
