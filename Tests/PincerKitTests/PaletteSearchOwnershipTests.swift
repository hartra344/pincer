#if DEBUG
import Foundation
import Testing
@testable import PincerKit

private actor PaletteCompletedGate {
    var entered = false, open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { if open { $0.resume() } else { continuation = $0 } }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
@MainActor @Suite(.timeLimit(.minutes(2))) struct PaletteSearchOwnershipTests {
    private func items() -> [PaletteItem] {
        [PaletteItem(id: "one", title: "First", symbol: "x", section: .chats, action: .command("one")),
         PaletteItem(id: "two", title: "Second", symbol: "x", section: .chats, action: .command("two"))]
    }
    private func entered(_ gate: PaletteCompletedGate) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await gate.entered) {
            try Task.checkCancellation()
            try #require(ContinuousClock.now < deadline, "actual completed worker must reach its gate")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @Test func newestQueryWaitsForActualLeaseAndRejectsPriorCompletion() async throws {
        let coordinator = PaletteSearchCoordinator(), gate = PaletteCompletedGate(), values = items()
        coordinator.appear(); coordinator.didPrepare = { await gate.hold() }
        let firstOwner = UUID(), firstRevision = coordinator.source.current
        let first = Task { await coordinator.prepare(values, bookmarks: [], query: "First", page: .root,
            gatewaySelected: false, shortcut: "CUSTOM", owner: firstOwner, revision: firstRevision) }
        var second: Task<Bool, Never>?
        do {
            try await entered(gate)
            let actual = try #require(coordinator.actualWorkerTask)
            coordinator.invalidate(); let secondOwner = UUID(), secondRevision = coordinator.source.current
            second = Task { await coordinator.prepare(values, bookmarks: [], query: "Second", page: .root,
                gatewaySelected: false, shortcut: "CUSTOM", owner: secondOwner, revision: secondRevision) }
            let deadline = ContinuousClock.now + .seconds(15)
            while coordinator.pendingCount != 1 {
                try Task.checkCancellation(); try #require(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(coordinator.activeCount == 1 && coordinator.pendingCount == 1 && !coordinator.owns(firstOwner))
            await gate.release(); await actual.value
            let oldAccepted = await first.value, newAccepted = await second?.value
            #expect(!oldAccepted && newAccepted == true)
            #expect(coordinator.result?.items.map(\.id) == ["two"] && coordinator.owns(secondOwner))
            #expect(coordinator.activeCount == 0 && coordinator.pendingCount == 0)
        } catch {
            first.cancel(); second?.cancel(); coordinator.disappear(); await gate.release()
            await first.value; await second?.value; throw error
        }
        coordinator.disappear()
    }
    enum Invalidation: CaseIterable { case source, disappear, cancel }
    @Test(arguments: Invalidation.allCases) func completedWorkerCannotPublishAfterInvalidation(_ mode: Invalidation) async throws {
        let coordinator = PaletteSearchCoordinator(), gate = PaletteCompletedGate(), values = items(), owner = UUID()
        coordinator.appear(); coordinator.didPrepare = { await gate.hold() }
        let revision = coordinator.source.current
        let request = Task { await coordinator.prepare(values, bookmarks: [], query: "First", page: .root,
            gatewaySelected: false, shortcut: nil, owner: owner, revision: revision) }
        do {
            try await entered(gate)
            let actual = try #require(coordinator.actualWorkerTask)
            switch mode {
            case .source: #expect(coordinator.source.changed(revision)) // Synchronous dirty mark; no queued Main rearm required.
            case .disappear: coordinator.disappear()
            case .cancel: request.cancel()
            }
            #expect(coordinator.activeCount == 1)
            await gate.release(); await actual.value
            let accepted = await request.value
            #expect(!accepted && coordinator.result == nil && !coordinator.owns(owner))
            #expect(coordinator.activeCount == 0)
        } catch {
            request.cancel(); coordinator.disappear(); await gate.release(); await request.value; throw error
        }
        coordinator.disappear()
    }
    @Test func canceledStandalonePreparationIsNotAnAcceptedEmptySearch() async {
        let values = items(), probe = PaletteSearchProbe()
        let canceled = Task { await PaletteSearchDiagnostics.$probe.withValue(probe) {
            await PaletteSearchPreparation.prepare(values, query: "First", page: .models, gatewaySelected: false)
        } }
        canceled.cancel()
        let discarded = await canceled.value
        #expect(discarded.isEmpty)
        let counts = probe.counts
        #expect(counts.main == [0, 0, 0] && counts.worker == [0, 0, 0])
        let current = await PaletteSearchPreparation.prepare(values, query: "First", page: .models, gatewaySelected: false)
        #expect(current.map(\.id) == ["one"])
    }
    @Test func rankingEnvironmentDoesNotRetireMessageSearch() {
        let owner = UUID(), gateway = UUID()
        let retained = PaletteSearchPreparation.ownerAfterEnvironmentChange(owner, page: .messages)
        #expect(retained == owner)
        #expect(PaletteSearchPreparation.messagesAreCurrent(owner: owner, currentOwner: retained, gateway: gateway, currentGateway: gateway))
        #expect(!PaletteSearchPreparation.messagesAreCurrent(owner: owner, currentOwner: UUID(), gateway: gateway, currentGateway: gateway))
        #expect(!PaletteSearchPreparation.messagesAreCurrent(owner: owner, currentOwner: owner, gateway: gateway, currentGateway: UUID()))
        #expect(PaletteSearchPreparation.ownerAfterEnvironmentChange(owner, page: .root) != owner)
    }
    @Test func finishedRankingRejectsChangedEnvironmentBeforeRefresh() async {
        let coordinator = PaletteSearchCoordinator(), owner = UUID()
        coordinator.appear()
        let original = PaletteEnvironmentKey(thinking: "original")
        let accepted = await coordinator.prepare(items(), bookmarks: [], query: "First", page: .models,
            gatewaySelected: false, shortcut: nil, owner: owner, revision: coordinator.source.current, environment: original)
        #expect(accepted && coordinator.result?.items.map(\.id) == ["one"])
        #expect(coordinator.owns(owner, environment: original))
        #expect(!coordinator.owns(owner, environment: PaletteEnvironmentKey(thinking: "changed")))
        #expect(!coordinator.owns(owner, environment: PaletteEnvironmentKey(thinking: "original", dictationScene: UUID())))
        coordinator.disappear()
    }

}
#endif
