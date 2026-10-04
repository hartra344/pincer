#if DEBUG
import Foundation
import Testing
@testable import PincerKit

private actor BookmarkEncodingGate {
    private var entries = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?
    private var open = false
    func holdFirst() async {
        entries += 1
        guard entries == 1 else { return }
        entered?.resume(); entered = nil
        await withCheckedContinuation { continuation in
            if open { continuation.resume() } else { held = continuation }
        }
    }
    func waitForEntry() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if entries > 0 || Task.isCancelled { continuation.resume() } else { entered = continuation }
            }
        } onCancel: { Task { await self.release() } }
        try Task.checkCancellation()
    }
    func release() { open = true; held?.resume(); held = nil; entered?.resume(); entered = nil }
    var count: Int { entries }
}

@MainActor @Suite(.timeLimit(.minutes(2)))
struct BookmarkPersistenceOrderingTests {
    private func entry(_ id: String) -> Bookmark { Bookmark(sessionKey: "main", messageId: id, preview: "Saved \(id)") }
    private func persisted(_ store: BookmarkStore, defaults: UserDefaults) async throws -> [Bookmark] {
        let data = try #require(defaults.data(forKey: store.defaultsKey))
        return try await Task.detached { try JSONDecoder().decode([Bookmark].self, from: data) }.value
    }

    @Test func oneActiveAndLatestSnapshotPreserveOrderingEvenWhenWaiterCancels() async throws {
        let scratch = ScratchDefaults(), gate = BookmarkEncodingGate()
        defer { scratch.remove() }
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        let probe = BookmarkPersistenceEncodingProbe()
        store.persistenceEncodingProbe = probe
        store.persistenceEncodingGate = { await gate.holdFirst() }
        store.add(entry("a"))
        do { try await gate.waitForEntry() } catch { await gate.release(); await store.waitForPersistenceEncoding(); throw error }
        let actual: Task<Void, Never>
        do { actual = try #require(store.actualPersistenceTask) }
        catch { await gate.release(); await store.waitForPersistenceEncoding(); throw error }
        store.add(entry("b")); store.add(entry("c")); store.remove(sessionKey: "main", messageId: "a")
        #expect(store.bookmarks.map(\.messageId) == ["c", "b"])
        #expect(store.persistenceActiveCount == 1 && store.persistencePendingCount == 1)
        let waiter = Task { await store.waitForPersistenceEncoding() }
        waiter.cancel()
        #expect(store.persistenceActiveCount == 1) // Canceling a caller does not free the actual worker.
        await gate.release(); await actual.value; await waiter.value
        let saved = try await persisted(store, defaults: scratch.defaults)
        #expect(saved == store.bookmarks)
        let visits = await gate.count
        #expect(visits == 2)
        #expect(probe.snapshot().main == 0 && probe.snapshot().worker == 2)
        #expect(store.persistenceActiveCount == 0 && store.persistencePendingCount == 0)
    }

    @Test(arguments: [false, true])
    func clearInvalidatesActualHeldSaveAndOnlyLaterMutationMayPersist(replace: Bool) async throws {
        let scratch = ScratchDefaults(), gate = BookmarkEncodingGate()
        defer { scratch.remove() }
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.persistenceEncodingGate = { await gate.holdFirst() }
        store.add(entry("old"))
        do { try await gate.waitForEntry() } catch { await gate.release(); await store.waitForPersistenceEncoding(); throw error }
        let actual: Task<Void, Never>
        do { actual = try #require(store.actualPersistenceTask) }
        catch { await gate.release(); await store.waitForPersistenceEncoding(); throw error }
        store.add(entry("pending")); store.removeAll()
        #expect(store.bookmarks.isEmpty && store.persistencePendingCount == 0)
        #expect(scratch.defaults.data(forKey: store.defaultsKey) == nil)
        if replace { store.add(entry("replacement")) }
        await gate.release(); await actual.value
        if replace {
            #expect(store.bookmarks.map(\.messageId) == ["replacement"])
            let saved = try await persisted(store, defaults: scratch.defaults)
        #expect(saved == store.bookmarks)
        } else {
            #expect(scratch.defaults.data(forKey: store.defaultsKey) == nil && store.bookmarks.isEmpty)
        }
        #expect(store.persistenceActiveCount == 0 && store.persistencePendingCount == 0)
    }

    @Test func preparedPreviewIsTheLatestPersistedSnapshot() async throws {
        let scratch = ScratchDefaults(), gate = BookmarkEncodingGate(), previewGate = BookmarkEncodingGate()
        defer { scratch.remove() }
        let store = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        store.previewPreparationQueue = BookmarkPreviewPreparationQueue(beforePrepare: { _ in await previewGate.holdFirst() })
        store.persistenceEncodingGate = { await gate.holdFirst() }
        var item = ChatItem(id: "local", role: .assistant, blocks: [.text("Hello weekend.")])
        item.transcriptId = "committed"
        #expect(store.toggle(item, sessionKey: "main"))
        do { try await gate.waitForEntry() } catch { await previewGate.release(); await gate.release(); await store.waitForPreviewPreparation(); await store.waitForPersistenceEncoding(); throw error }
        let actual: Task<Void, Never>
        do { actual = try #require(store.actualPersistenceTask) }
        catch {
            await previewGate.release(); await gate.release()
            await store.waitForPreviewPreparation(); await store.waitForPersistenceEncoding()
            throw error
        }
        await previewGate.release()
        await withTaskCancellationHandler {
            await store.waitForPreviewPreparation()
        } onCancel: { Task { await previewGate.release(); await gate.release() } }
        #expect(store.bookmarks.first?.preview == "Hello weekend." && store.persistencePendingCount == 1)
        await gate.release(); await actual.value
        let saved = try await persisted(store, defaults: scratch.defaults)
        #expect(saved == store.bookmarks)
    }
    @Test func acceptedPersistenceOutlivesTheCallersStoreReference() async throws {
        let scratch = ScratchDefaults(), gate = BookmarkEncodingGate()
        defer { scratch.remove() }
        var store: BookmarkStore? = BookmarkStore(gatewayId: UUID(), defaults: scratch.defaults)
        let key = try #require(store?.defaultsKey)
        let expected = entry("durable")
        store?.persistenceEncodingGate = { await gate.holdFirst() }
        store?.add(expected)
        do { try await gate.waitForEntry() } catch { await gate.release(); await store?.waitForPersistenceEncoding(); throw error }
        let actual: Task<Void, Never>
        do {
            // Keep the owned store available to drain if capture itself fails.
            let cleanupStore = try #require(store)
            do { actual = try #require(cleanupStore.actualPersistenceTask) }
            catch { await gate.release(); await cleanupStore.waitForPersistenceEncoding(); throw error }
        } catch { await gate.release(); await store?.waitForPersistenceEncoding(); throw error }
        store = nil
        await gate.release(); await actual.value
        let data = try #require(scratch.defaults.data(forKey: key))
        let saved = try await Task.detached { try JSONDecoder().decode([Bookmark].self, from: data) }.value
        #expect(saved == [expected])
    }

}
#endif
