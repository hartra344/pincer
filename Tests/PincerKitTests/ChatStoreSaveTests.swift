import Foundation
import Testing
@testable import PincerKit

/// A chat saves only when its content changed, never over a cache it couldn't read, and the
/// prefetch skips chats that are already as fresh as they can get (#199).
@Suite("Chat store cache saves", .serialized, .enabled(if: TranscriptCache.root != nil))
@MainActor
struct ChatStoreSaveTests {
    let key = "agent:main:main"

    func makeStore() -> (ChatStore, GatewayStore) {
        let suite = "ChatStoreSaveTests.\(UUID().uuidString)"
        let profile = GatewayProfile(id: UUID(), name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = GatewayStore(profile: profile, defaults: UserDefaults(suiteName: suite)!, identity: Fixtures.identity())
        let chat = ChatStore(sessionKey: self.key, agentId: nil, gateway: gateway, headless: true)
        return (chat, gateway)
    }

    func manifest(_ gateway: GatewayStore) -> URL {
        TranscriptCache.file(gatewayId: gateway.id, sessionKey: self.key)!
    }

    func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @Test func unchangedRefreshDoesNotSave() async throws {
        let (chat, gateway) = self.makeStore()
        defer { TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true) }
        let items = V8.items(30)
        chat.items = items
        chat.hasLoaded = true
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id)
        let url = self.manifest(gateway)
        let first = try #require(self.mtime(url))

        try await Task.sleep(for: .milliseconds(30))
        chat.items = items
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id)
        #expect(self.mtime(url) == first)

        chat.items = items + V8.items(1, from: 30)
        await chat.saveSnapshot()
        await TranscriptCache.flush(gatewayId: gateway.id)
        #expect(try #require(self.mtime(url)) > first)
    }

    @Test func unavailableRestoreDoesNotSaveAndRetries() async throws {
        let (chat, gateway) = self.makeStore()
        defer { TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true) }
        let old = V8.items(400)
        await TranscriptCache.save(V8.snapshot(old), gatewayId: gateway.id, sessionKey: self.key)
        await TranscriptCache.flush(gatewayId: gateway.id)
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
        await TranscriptCache.flush(gatewayId: gateway.id)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before)

        chat.items = []
        await chat.restoreFromCache()
        #expect(chat.cacheOutcome == .loaded)
        #expect(chat.items.count == 400)
    }

    @Test func retryAfterUnavailableMergesOlderHistory() async throws {
        let (chat, gateway) = self.makeStore()
        defer { TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true) }
        let all = V8.items(400)
        await TranscriptCache.save(V8.snapshot(all), gatewayId: gateway.id, sessionKey: self.key)
        await TranscriptCache.flush(gatewayId: gateway.id)
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
        await TranscriptCache.flush(gatewayId: gateway.id)
        let saved = try #require(await TranscriptCache.load(gatewayId: gateway.id, sessionKey: self.key))
        #expect(saved.items.count == 401 && saved.items.first?.id == all.first?.id)
    }

    @Test func retryWithoutOverlapSplicesNothing() async throws {
        let (chat, gateway) = self.makeStore()
        defer { TranscriptCache.removeAll(gatewayId: gateway.id, permanently: true) }
        let cached = V8.items(100)
        await TranscriptCache.save(V8.snapshot(cached), gatewayId: gateway.id, sessionKey: self.key)
        await TranscriptCache.flush(gatewayId: gateway.id)
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
