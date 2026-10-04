import Foundation
import Testing

/// Only fixtures that deliberately evict global text caches or assert a warm window use this
/// lease. It never blocks Main while a fixture awaits the real measurement worker.
@MainActor
final class TranscriptSharedCacheLease {
    static let shared = TranscriptSharedCacheLease()
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    var waitingCount: Int { self.waiters.count }
    func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else if !self.held { self.held = true; continuation.resume(returning: true) }
                else { self.waiters.append((id, continuation)) }
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = self.waiters.firstIndex(where: { $0.0 == id }) else { return }
        self.waiters.remove(at: index).1.resume(returning: false)
    }
    func release() {
        if self.waiters.isEmpty { self.held = false }
        else { self.waiters.removeFirst().1.resume(returning: true) }
    }
}

@MainActor
struct TranscriptSharedCacheLeaseTests {
    @Test(.timeLimit(.minutes(2))) func cancellationRemovesAWaitingFixtureAndLetsTheNextProceed() async throws {
        let lease = TranscriptSharedCacheLease()
        try #require(await lease.acquire())
        let cancelled = Task { await lease.acquire() }
        let next = Task { await lease.acquire() }
        defer { cancelled.cancel(); next.cancel(); lease.release() }
        try #require(await eventually { lease.waitingCount == 2 })
        cancelled.cancel()
        #expect(await cancelled.value == false)
        lease.release()
        #expect(await next.value)
        lease.release()
        #expect(await lease.acquire())
        lease.release()
    }
}
