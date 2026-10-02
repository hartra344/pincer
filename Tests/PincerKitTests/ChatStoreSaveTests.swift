import Foundation
import Testing
@testable import PincerKit

/// A chat saves only when its content changed, never over a cache it couldn't read, and the
/// prefetch skips chats that are already as fresh as they can get (#199).
@Suite("Chat store cache saves", .serialized)
@MainActor
struct ChatStoreSaveTests {
    let key = "agent:main:main"
    let temp = TempDir()

    @MainActor
    private final class ManualSaveScheduler {
        private struct Waiter {
            let deadline: Date
            let continuation: CheckedContinuation<Void, Error>
        }

        var now = Date(timeIntervalSince1970: 1_700_000_000)
        private var waiters: [UUID: Waiter] = [:]
        private var registrations: [CheckedContinuation<Void, Never>] = []
        private var idleWaiters: [CheckedContinuation<Void, Never>] = []

        var pendingDeadlines: [Date] { self.waiters.values.map(\.deadline) }

        func wait(until deadline: Date) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    let registrations = self.registrations
                    self.registrations.removeAll()
                    registrations.forEach { $0.resume() }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(id) }
            }
        }

        func waitUntilScheduled() async {
            guard self.waiters.isEmpty else { return }
            await withCheckedContinuation { self.registrations.append($0) }
        }

        func waitUntilIdle() async {
            guard !self.waiters.isEmpty else { return }
            await withCheckedContinuation { self.idleWaiters.append($0) }
        }

        func cancel(_ id: UUID) {
            guard let waiter = self.waiters.removeValue(forKey: id) else { return }
            waiter.continuation.resume(throwing: CancellationError())
            if self.waiters.isEmpty {
                let waiters = self.idleWaiters
                self.idleWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
    }

    func makeStore(headless: Bool = true) -> (ChatStore, GatewayStore) {
        let suite = "ChatStoreSaveTests.\(UUID().uuidString)"
        let profile = GatewayProfile(id: UUID(), name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: UserDefaults(suiteName: suite)!, identity: Fixtures.identity())
        gateway.cacheRoot = self.temp.url
        let chat = ChatStore(sessionKey: self.key, agentId: nil, gateway: gateway, headless: headless)
        return (chat, gateway)
    }

    @Test func liveTranscriptUsesBoundedFiveSecondSaveDeadline() async {
        let (chat, gateway) = self.makeStore(headless: false)
        let scheduler = ManualSaveScheduler()
        chat.saveNow = { scheduler.now }
        chat.waitForSaveDeadline = { try await scheduler.wait(until: $0) }
        chat.hasLoaded = true
        chat.live = LiveRun(runId: "stream")
        chat.items = V8.items(1)
        await scheduler.waitUntilScheduled()

        let firstDeadline = scheduler.now.addingTimeInterval(5)
        #expect(chat.saveDeadline == firstDeadline,
                "a live transcript should not hit the ordinary one-second save debounce")
        #expect(scheduler.pendingDeadlines == [firstDeadline])

        // Later deltas keep the first deadline instead of extending the save window.
        scheduler.now = scheduler.now.addingTimeInterval(4)
        chat.items = V8.items(2)
        #expect(chat.saveDeadline == firstDeadline)

        // The run's terminal event flushes immediately, even though the scheduled waiter is pending.
        chat.flushScheduledSave()
        #expect(chat.saveDeadline == scheduler.now)

        chat.stopCaching()
        #expect(chat.saveDeadline == nil)
        await scheduler.waitUntilIdle()
        TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
        self.temp.remove()
    }

    @Test func committedUserMessageKeepsSearchAheadOfStreamingSaveWindow() async {
        let (chat, gateway) = self.makeStore(headless: false)
        let scheduler = ManualSaveScheduler()
        chat.saveNow = { scheduler.now }
        chat.waitForSaveDeadline = { try await scheduler.wait(until: $0) }
        chat.hasLoaded = true
        chat.items = V8.items(1)
        let idleDeadline = scheduler.now.addingTimeInterval(1)
        #expect(chat.saveDeadline == idleDeadline)
        chat.live = LiveRun(runId: "searchable-send")
        chat.items = V8.items(2)
        #expect(chat.saveDeadline == idleDeadline,
                "starting a run must not postpone an already queued one-second save")
        chat.handleSessionMessage(["message": ["role": "user", "content": "remember searchable-send", "__openclaw": ["id": "search-user"]]])
        #expect(chat.saveDeadline == scheduler.now,
                "the committed user message is a persistence and search-index boundary")
        chat.items = chat.items + V8.items(1, from: 3)
        #expect(chat.saveDeadline == scheduler.now, "streamed output cannot postpone the user-message boundary")
        chat.stopCaching()
        await scheduler.waitUntilIdle()
        TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url)
        self.temp.remove()
    }

    func manifest(_ gateway: GatewayStore) -> URL {
        TranscriptCache.file(gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)!
    }

    func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @Test func unchangedRefreshDoesNotSave() async throws {
        let (chat, gateway) = self.makeStore()
        defer { TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url) ; self.temp.remove() }
        let items = V8.items(30)
        chat.items = items
        chat.hasLoaded = true
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        let url = self.manifest(gateway)
        let first = try #require(self.mtime(url))

        try await Task.sleep(for: .milliseconds(30))
        chat.items = items
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        #expect(self.mtime(url) == first)

        chat.items = items + V8.items(1, from: 30)
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        #expect(try #require(self.mtime(url)) > first)
    }

    @Test func completedWriteMarksOnlyTheCapturedRevisionAsSaved() {
        let (chat, gateway) = self.makeStore()
        defer { TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url) ; self.temp.remove() }
        chat.items = V8.items(1)
        let captured = chat.currentCacheState

        // Model a transcript edit while the asynchronous disk writer is suspended.
        chat.items = V8.items(2)
        chat.recordSavedSnapshot(captured, result: TranscriptCache.SaveResult(unchanged: true))

        #expect(chat.savedState == captured)
        #expect(chat.currentCacheState != chat.savedState,
                "the later revision must remain dirty for a follow-up save")
    }

    @Test func unavailableRestoreDoesNotSaveAndRetries() async throws {
        let (chat, gateway) = self.makeStore()
        defer { TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url) ; self.temp.remove() }
        let old = V8.items(400)
        await TranscriptCache.save(V8.snapshot(old), gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        let url = self.manifest(gateway)
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        await chat.restoreFromCache()
        guard case .unavailable = chat.cacheOutcome else {
            Issue.record("expected unavailable, got \(String(describing: chat.cacheOutcome))")
            return
        }
        #expect(!chat.cacheChecked)

        chat.items = Array(old.suffix(20))
        chat.hasLoaded = true
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before)

        chat.items = []
        await chat.restoreFromCache()
        #expect(chat.cacheOutcome == .loaded)
        #expect(chat.items.count == 400)
    }

    @Test func retryAfterUnavailableMergesOlderHistory() async throws {
        let (chat, gateway) = self.makeStore()
        defer { TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url) ; self.temp.remove() }
        let all = V8.items(400)
        await TranscriptCache.save(V8.snapshot(all), gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        let url = self.manifest(gateway)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        await chat.restoreFromCache()
        chat.items = Array(all.suffix(20))
        chat.hasLoaded = true
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        await chat.restoreFromCache()
        #expect(chat.cacheOutcome == .loaded)
        #expect(chat.items.map(\.id) == all.map(\.id))

        chat.items.append(contentsOf: V8.items(1, from: 400))
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        let saved = try #require(await TranscriptCache.load(gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url))
        #expect(saved.items.count == 401 && saved.items.first?.id == all.first?.id)
    }

    @Test func retryWithoutOverlapSplicesNothing() async throws {
        let (chat, gateway) = self.makeStore()
        defer { TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true, root: self.temp.url) ; self.temp.remove() }
        let cached = V8.items(100)
        await TranscriptCache.save(V8.snapshot(cached), gatewayId: gateway.id, sessionKey: self.key, root: self.temp.url)
        await TranscriptCache.flush(gatewayId: gateway.id, root: self.temp.url)
        let url = self.manifest(gateway)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        await chat.restoreFromCache()
        // The newest page starts well after the cache ends: messages in between are unknown.
        let page = V8.items(20, from: 500)
        chat.items = page
        chat.hasLoaded = true
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        await chat.restoreFromCache()
        #expect(chat.cacheOutcome == .loaded)
        #expect(chat.items.map(\.id) == page.map(\.id))
    }

    @Test func snapshotMarksRetainedWhenCutAtMaxItems() {
        let items = V8.items(50)
        let cut = ChatStore.snapshot(items: items, hasMoreHistory: true, activityMs: nil, maxItems: 30)
        #expect(cut.items.count == 30 && cut.retained && !cut.complete)
        let whole = ChatStore.snapshot(items: items, hasMoreHistory: false, activityMs: nil, maxItems: 50)
        #expect(!whole.retained && whole.complete)
        let partial = ChatStore.snapshot(items: items, hasMoreHistory: true, activityMs: nil, maxItems: 100)
        #expect(!partial.retained && !partial.complete)
        let exact = ChatStore.snapshot(items: items, hasMoreHistory: true, activityMs: nil, maxItems: 50)
        #expect(exact.retained)
    }

    @Test func prefetchSkipsFreshChatsOnly() {
        func meta(complete: Bool, retained: Bool?, activity: Double?) -> TranscriptCache.Meta {
            TranscriptCache.Meta(complete: complete, activityMs: activity, version: TranscriptCache.Snapshot.currentVersion,
                                 retained: retained)
        }
        #expect(GatewayStore.prefetchIsFresh(meta(complete: true, retained: nil, activity: 10), activityMs: 10))
        #expect(GatewayStore.prefetchIsFresh(meta(complete: false, retained: true, activity: 10), activityMs: 5))
        #expect(!GatewayStore.prefetchIsFresh(meta(complete: false, retained: true, activity: 10), activityMs: 11))
        #expect(!GatewayStore.prefetchIsFresh(meta(complete: false, retained: false, activity: 10), activityMs: 5))
        #expect(!GatewayStore.prefetchIsFresh(meta(complete: true, retained: nil, activity: nil), activityMs: 5))
        #expect(!GatewayStore.prefetchIsFresh(nil, activityMs: 5))
    }
}
