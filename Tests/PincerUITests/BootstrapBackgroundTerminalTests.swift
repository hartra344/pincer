#if DEBUG
import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Actual bootstrap background terminal ownership", .timeLimit(.minutes(2)))
struct BootstrapBackgroundTerminalTests {
    actor Gate {
        var entered = false
        var open = false
        var holdWaiter: CheckedContinuation<Void, Never>?
        var entryWaiter: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            entryWaiter?.resume(); entryWaiter = nil
            if !open { await withCheckedContinuation { holdWaiter = $0 } }
        }
        func wait() async {
            if !entered, !open { await withCheckedContinuation { entryWaiter = $0 } }
        }
        func release() {
            open = true
            holdWaiter?.resume(); holdWaiter = nil
            entryWaiter?.resume(); entryWaiter = nil
        }
    }

    @Test
    func realDemoBootstrapTaskRemainsOwnedUntilReconciliationCompletes() async throws {
        let suite = "bootstrap-terminal-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gateway = GatewayStore(profile: .demo(), defaults: defaults)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        let gate = Gate()
        gateway.beforeBootstrapReconciliation = { await gate.hold() }
        gateway.start(); gateway.reconnectIfNeeded()
        defer { Task { await gate.release() }; gateway.stop() }
        try await withTaskCancellationHandler {
            await gate.wait()
            let actualTask = try #require(gateway.bootstrapBackgroundTask)
            #expect(gateway.state.isConnected)
            #expect(!gateway.sessions.isEmpty)
            #expect(gateway.bootstrapBackgroundTask != nil)
            await gate.release()
            await actualTask.value
            #expect(gateway.bootstrapBackgroundTask == nil)
            #expect(gateway.state.isConnected)
            #expect(!gateway.sessions.isEmpty)
        } onCancel: {
            Task { await gate.release() }
        }
    }

    @Test
    func completedPriorEpochDoesNotMarkNewDemoBootstrapTerminal() async throws {
        let suite = "bootstrap-new-epoch-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gateway = GatewayStore(profile: .demo(), defaults: defaults)
        gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
        let first = Gate(), second = Gate()
        gateway.beforeBootstrapReconciliation = { await first.hold() }
        gateway.start()
        defer { Task { await first.release(); await second.release() }; gateway.stop() }
        try await withTaskCancellationHandler {
            await first.wait()
            let firstTask = try #require(gateway.bootstrapBackgroundTask)
            let firstMain = try #require(gateway.bootstrapMainTask)
            let priorEpoch = gateway.bootstrapProbeEpoch
            await first.release()
            await firstTask.value; await firstMain.value
            #expect(gateway.bootstrapProbeIsTerminal)
            #expect(gateway.bootstrapLastBackgroundTask != nil)
            gateway.beforeBootstrapReconciliation = { await second.hold() }
            await gateway.connection.stop()
            await gateway.connection.start()
            await second.wait()
            let secondTask = try #require(gateway.bootstrapBackgroundTask)
            let secondMain = try #require(gateway.bootstrapMainTask)
            #expect(gateway.bootstrapProbeEpoch > priorEpoch)
            #expect(!gateway.bootstrapProbeIsTerminal)
            #expect(!gateway.sessions.isEmpty)
            await second.release()
            await secondTask.value; await secondMain.value
            #expect(gateway.bootstrapProbeIsTerminal)
        } onCancel: { Task { await first.release(); await second.release() } }
    }

}
#endif
