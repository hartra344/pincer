#if DEBUG
import Foundation
@testable import PincerKit

@MainActor private final class BookmarkLocalSaveGate {
    var entered = false
    private var first = true
    private var open = false
    private var continuation: CheckedContinuation<Void, Never>?
    func holdFirst() async {
        guard first else { return }
        first = false; entered = true
        await withCheckedContinuation { continuation in
            if open { continuation.resume() } else { self.continuation = continuation }
        }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}

@MainActor func runBookmarkPersistenceOrderingChecks() async {
    for clear in [false, true] {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookmarkStore(gatewayId: UUID(), defaults: defaults)
        let gate = BookmarkLocalSaveGate(), probe = BookmarkPersistenceEncodingProbe()
        store.persistenceEncodingGate = { await gate.holdFirst() }
        store.persistenceEncodingProbe = probe
        store.add(Bookmark(sessionKey: "main", messageId: "old", preview: "Old saved message"))
        let entered = await waitFor("actual bookmark encoder admission") { gate.entered }
        check(entered, "actual local encoder reaches the controlled worker boundary")
        guard entered, let actual = store.actualPersistenceTask else {
            gate.release(); await store.waitForPersistenceEncoding(); check(false, "actual persistence task is captured"); return
        }
        store.add(Bookmark(sessionKey: "main", messageId: "middle", preview: "Middle saved message"))
        store.add(Bookmark(sessionKey: "main", messageId: "latest", preview: "Latest saved message"))
        store.remove(sessionKey: "main", messageId: "old")
        check(store.bookmarks.map(\.messageId) == ["latest", "middle"] && store.persistenceActiveCount == 1 && store.persistencePendingCount == 1,
              "actual local saves coalesce only the latest snapshot with one active encoder")
        if clear { store.removeAll() }
        let waiter = Task { await store.waitForPersistenceEncoding() }; waiter.cancel()
        check(store.persistenceActiveCount == 1, "canceling a waiter cannot release actual encoder ownership")
        gate.release(); await actual.value; await waiter.value
        if clear {
            check(defaults.data(forKey: store.defaultsKey) == nil && store.bookmarks.isEmpty,
                  "Clear cannot be resurrected by the actual held old encoder")
        } else {
            guard let data = defaults.data(forKey: store.defaultsKey) else { check(false, "latest saved bookmark data exists"); return }
            do {
                let saved = try await Task.detached { try JSONDecoder().decode([Bookmark].self, from: data) }.value
                check(saved == store.bookmarks && !saved.isEmpty, "actual coalesced persistence retains the complete latest ordered collection")
            } catch { check(false, "actual coalesced bookmark data decodes"); return }
        }
        let stats = probe.snapshot()
        check(stats.main == 0 && stats.worker == (clear ? 1 : 2), "actual encoder visits only active and latest sources off Main")
        check(store.persistenceActiveCount == 0 && store.persistencePendingCount == 0, "actual completed persistence leaves no owned backlog")
    }
}
#endif
