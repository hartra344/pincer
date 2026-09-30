import Foundation
import Testing
@testable import PincerKit

/// #482: large uploads wait on expensive / constrained networks; Send Now overrides per entry.
@MainActor
@Suite("Outbox hold")
struct OutboxHoldTests {
    let scratch = ScratchDefaults()
    let temp = TempDir()
    let key = "agent:main:main"
    let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:9", authMode: .none)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func ref(_ bytes: Int) -> OutboxAttachmentRef {
        OutboxAttachmentRef(id: UUID(), fileName: "big.bin", mimeType: "application/octet-stream", byteCount: bytes)
    }

    func entry(_ id: String, _ session: String = "agent:main:main", bytes: Int? = nil) -> OutboxEntry {
        OutboxEntry(id: id, sessionKey: session, text: id, createdAt: self.now, attachments: bytes.map { [self.ref($0)] } ?? [])
    }

    func store(_ network: NetworkConditions) -> GatewayStore {
        let store = GatewayStore(profile: self.profile, defaults: self.scratch.defaults,
                                 identity: Fixtures.identity(), network: network)
        store.outboxRoot = self.temp.url
        return store
    }

    func finish(_ store: GatewayStore) {
        store.stop()
        self.temp.remove()
        self.scratch.remove()
    }

    let large = OutboxEntry.largeUploadBytes + 1

    // MARK: Pure

    @Test func attachmentBytesSumsRefs() {
        var item = self.entry("a", bytes: 100)
        item.attachments.append(self.ref(50))
        #expect(item.attachmentBytes == 150)
        #expect(self.entry("t").attachmentBytes == 0)
    }

    @Test func heldEntrySkippedAndBlocksOnlyItsChat() {
        var box = Outbox()
        for item in [self.entry("big", bytes: self.large), self.entry("after"), self.entry("x", "agent:other:main")] {
            box.enqueue(item)
        }
        let holding: (OutboxEntry) -> Bool = { $0.id == "big" }
        #expect(box.nextToSend(sessionKey: self.key, holding: holding) == nil, "later entries wait behind the held one")
        #expect(box.nextToSend(sessionKey: "agent:other:main", holding: holding)?.id == "x")
        #expect(box.nextToSend(holding: holding)?.id == "x", "other chats still flow")
        #expect(box.nextToSend(sessionKey: self.key)?.id == "big", "no hold → in order as before")
    }

    @Test func releasingTheHoldKeepsOrder() {
        var box = Outbox()
        for item in [self.entry("big", bytes: self.large), self.entry("after")] { box.enqueue(item) }
        var order: [String] = []
        while let next = box.nextToSend(sessionKey: self.key, holding: { _ in false }) {
            box.markSending(id: next.id)
            order.append(next.id)
            box.markSent(id: next.id)
        }
        #expect(order == ["big", "after"])
    }

    @Test func allowAnyNetworkSetsTheOverride() {
        var box = Outbox()
        box.enqueue(self.entry("big", bytes: self.large))
        #expect(box.entry(id: "big")?.sendOnAnyNetwork == false)
        box.allowAnyNetwork(id: "big")
        #expect(box.entry(id: "big")?.sendOnAnyNetwork == true)
        box.allowAnyNetwork(id: "missing")
    }

    @Test func sendOnAnyNetworkCodableBackCompat() throws {
        let item = self.entry("x")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object.removeValue(forKey: "sendOnAnyNetwork")
        let old = try JSONDecoder().decode(OutboxEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!old.sendOnAnyNetwork, "older files decode as not overridden")
        var flagged = item
        flagged.sendOnAnyNetwork = true
        let round = try JSONDecoder().decode(OutboxEntry.self, from: JSONEncoder().encode(flagged))
        #expect(round.sendOnAnyNetwork)
    }

    // MARK: Store

    /// Holds need a connected Gateway (only the flush holds; offline entries are just queued), so
    /// the connected cases live in the live checks.
    @Test func offlineEntriesAreNeverHeld() {
        let network = NetworkConditions()
        let store = self.store(network)
        defer { self.finish(store) }
        let big = self.entry("big", bytes: self.large)
        store.injectOutboxEntry(big)
        for (expensive, constrained) in [(false, false), (true, false), (true, true), (false, true)] {
            network.override(expensive: expensive, constrained: constrained)
            #expect(store.hold(for: big) == nil)
        }
        store.resyncOutboxHolds()
        #expect(store.chat(for: self.key).items.first { $0.idempotencyKey == "big" }?.outboxHold == nil)
    }

    @Test func sendNowMarksTheEntry() {
        let store = self.store(NetworkConditions())
        defer { self.finish(store) }
        store.injectOutboxEntry(self.entry("big", bytes: self.large))
        store.chat(for: self.key).sendNow(outboxId: "big")
        #expect(store.outbox.entry(id: "big")?.sendOnAnyNetwork == true)
    }

    @Test func thresholdIsTwoMebibytes() {
        #expect(OutboxEntry.largeUploadBytes == 2 * 1024 * 1024)
    }

    // MARK: Connected (the in-process demo Gateway, which sends a hello)

    func connected(_ network: NetworkConditions) async -> GatewayStore? {
        let store = GatewayStore(profile: .demo(), defaults: self.scratch.defaults, identity: Fixtures.identity(), network: network)
        store.outboxRoot = self.temp.url
        store.start()
        let ready = await eventually(timeout: .seconds(10)) { store.state.isConnected && store.hello != nil }
        if !ready { self.finish(store) }
        return ready ? store : nil
    }

    func row(_ store: GatewayStore, _ key: String, _ id: String) -> ChatItem? {
        store.chat(for: key).items.first { $0.idempotencyKey == id }
    }

    @Test func connectedHoldFollowsSizeNetworkAndOverride() async throws {
        let network = NetworkConditions()
        let store = try #require(await self.connected(network))
        defer { self.finish(store) }
        let chat = "agent:held:main"
        let big = self.entry("big", chat, bytes: self.large)
        store.injectOutboxEntry(big)
        network.override(expensive: false, constrained: false)
        #expect(store.hold(for: big) == nil, "an unmetered network holds nothing")
        network.override(expensive: true, constrained: false)
        #expect(store.hold(for: big) == .expensive)
        let small = self.entry("small", "agent:small:main", bytes: 1024)
        store.injectOutboxEntry(small)
        #expect(store.hold(for: small) == nil, "small uploads never wait")
        network.override(expensive: true, constrained: true)
        #expect(store.hold(for: big) == .constrained, "constrained wins")
        network.override(expensive: true, constrained: false)
        store.outbox.allowAnyNetwork(id: "big")
        #expect(store.hold(for: store.outbox.entry(id: "big")!) == nil, "Send Now lifts it")
    }

    @Test func behindAFailedEntryIsJustQueued() async throws {
        let network = NetworkConditions()
        let store = try #require(await self.connected(network))
        defer { self.finish(store) }
        network.override(expensive: true, constrained: false)
        let chat = "agent:held:main"
        var failed = self.entry("head", chat)
        failed.state = .failed(OutboxFailure(message: "no", retryable: false))
        store.injectOutboxEntry(failed)
        let big = self.entry("big", chat, bytes: self.large)
        store.injectOutboxEntry(big)
        #expect(store.hold(for: big) == nil, "not next to send, so no hold")
        #expect(store.hold(for: failed) == nil)
        store.outbox.delete(id: "head")
        #expect(store.hold(for: big) == .expensive, "held once it is next in line")
    }

    @Test func rowsFollowTheNetworkAndSendNow() async throws {
        let network = NetworkConditions()
        let store = try #require(await self.connected(network))
        defer { self.finish(store) }
        let chat = "agent:held:main"
        store.injectOutboxEntry(self.entry("big", chat, bytes: self.large))
        store.resyncOutboxHolds()
        #expect(self.row(store, chat, "big")?.outboxHold == nil)
        network.override(expensive: true, constrained: false)
        store.resyncOutboxHolds()
        #expect(self.row(store, chat, "big")?.outboxHold == .expensive)
        #expect(self.row(store, chat, "big")?.outboxUploadBytes == self.large)
        network.override(expensive: false, constrained: true)
        store.resyncOutboxHolds()
        #expect(self.row(store, chat, "big")?.outboxHold == .constrained)
        network.override(expensive: true, constrained: false)
        store.chat(for: chat).sendNow(outboxId: "big")
        store.resyncOutboxHolds()
        #expect(store.outbox.entry(id: "big")?.sendOnAnyNetwork == true || store.outbox.entry(id: "big") == nil)
        #expect(self.row(store, chat, "big")?.outboxHold == nil)
    }
}
