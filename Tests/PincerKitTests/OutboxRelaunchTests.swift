import Foundation
import Testing
@testable import PincerKit

/// #414: editing a Gateway replaces its store; the new one must pick up every queued message the
/// old one had, even while the old one's writes are still queued, and the old one mustn't write
/// over it afterwards.
@MainActor
@Suite("Outbox across a store replacement")
struct OutboxRelaunchTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()

    func entry(_ id: String) -> OutboxEntry {
        OutboxEntry(id: id, sessionKey: "agent:main:main", text: "message \(id)", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Waits for the store's saved outbox to be read (the load `start()` kicks off), not for a clock:
    /// the read queues behind utility-priority writes, which a loaded machine can starve for a long
    /// while. The timeout is only a safety net.
    func restored(_ store: GatewayStore) async -> Bool {
        if let load = store.outboxLoadTask {
            let (first, done) = AsyncStream.makeStream(of: Void.self)
            let watcher = Task {
                await load.value
                done.yield()
            }
            let safetyNet = Task {
                try? await Task.sleep(for: .seconds(120))
                done.yield()
            }
            for await _ in first { break }
            watcher.cancel()
            safetyNet.cancel()
        }
        return await eventually(timeout: .seconds(1)) { store.outboxRestored }
    }

    @Test func editingAGatewayKeepsItsQueuedMessages() async throws {
        defer {
            self.temp.remove()
            self.scratch.remove()
        }
        let app = AppModel(defaults: self.scratch.defaults)
        let old = app.add(GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none), secret: nil)
        old.outboxRoot = self.temp.url // before `start()`'s load runs
        #expect(await self.restored(old))
        old.injectOutboxEntry(self.entry("a"))
        old.injectOutboxEntry(self.entry("b"))

        app.update(old.profile, secret: nil, credentialsChanged: false)
        let replacement = try #require(app.gateways.first { $0.id == old.id })
        defer { replacement.stop() }
        #expect(replacement !== old)
        #expect(await self.restored(replacement))
        #expect(replacement.outbox.entries.map(\.id) == ["a", "b"], "both queued messages survive the edit")

        // A send finishing on the old store afterwards doesn't write over the file.
        old.injectOutboxEntry(self.entry("late"))
        await OutboxStore.flushWrites(gatewayId: old.id, root: self.temp.url)
        let saved = await OutboxStore.load(gatewayId: old.id, root: self.temp.url).outbox
        #expect(saved?.entries.map(\.id) == ["a", "b"])
    }

    @Test func quitSavesWhatsStillQueued() async throws {
        defer {
            self.temp.remove()
            self.scratch.remove()
        }
        let app = AppModel(defaults: self.scratch.defaults)
        let store = app.add(GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none), secret: nil)
        store.outboxRoot = self.temp.url
        defer { store.stop() }
        #expect(await self.restored(store))
        store.injectOutboxEntry(self.entry("a"))
        app.saveOutboxesNow()
        let file = try #require(OutboxStore.file(gatewayId: store.id, root: self.temp.url))
        let data = try Data(contentsOf: file)
        #expect(OutboxStore.decode(data).outbox?.entries.map(\.id) == ["a"], "written before returning")
    }
}
