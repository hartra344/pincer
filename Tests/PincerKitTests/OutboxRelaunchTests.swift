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

    func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10)) // poll interval
        }
        return condition()
    }

    @Test func editingAGatewayKeepsItsQueuedMessages() async throws {
        defer {
            self.temp.remove()
            self.scratch.remove()
        }
        let app = AppModel(defaults: self.scratch.defaults)
        let old = app.add(GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none), secret: nil)
        old.outboxRoot = self.temp.url // before `start()`'s load runs
        #expect(await self.eventually { old.outboxRestored })
        old.injectOutboxEntry(self.entry("a"))
        old.injectOutboxEntry(self.entry("b"))

        app.update(old.profile, secret: nil, credentialsChanged: false)
        let replacement = try #require(app.gateways.first { $0.id == old.id })
        defer { replacement.stop() }
        #expect(replacement !== old)
        #expect(await self.eventually { replacement.outboxRestored })
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
        #expect(await self.eventually { store.outboxRestored })
        store.injectOutboxEntry(self.entry("a"))
        app.saveOutboxesNow()
        let file = try #require(OutboxStore.file(gatewayId: store.id, root: self.temp.url))
        let data = try Data(contentsOf: file)
        #expect(OutboxStore.decode(data).outbox?.entries.map(\.id) == ["a"], "written before returning")
    }
}
