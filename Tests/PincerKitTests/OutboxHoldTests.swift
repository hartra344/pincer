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

    @Test func holdFollowsSizeNetworkAndOverride() {
        let network = NetworkConditions()
        let store = self.store(network)
        defer { self.finish(store) }
        let big = self.entry("big", bytes: self.large)
        let small = self.entry("small", bytes: 1024)
        store.injectOutboxEntry(big)
        store.injectOutboxEntry(small)
        #expect(store.hold(for: big) == nil, "unmetered network: nothing held")

        network.override(expensive: true, constrained: false)
        #expect(store.hold(for: big) == .expensive)
        #expect(store.hold(for: small) == nil, "small uploads never wait")
        #expect(store.hold(for: self.entry("text")) == nil)

        network.override(expensive: true, constrained: true)
        #expect(store.hold(for: big) == .constrained, "constrained wins when both")

        network.override(expensive: false, constrained: true)
        #expect(store.hold(for: big) == .constrained)

        store.outbox.allowAnyNetwork(id: "big")
        let overridden = store.outbox.entry(id: "big")!
        #expect(store.hold(for: overridden) == nil, "Send Now lifts the hold")
        network.override(expensive: false, constrained: false)
    }

    @Test func onlyQueuedEntriesAreHeld() {
        let network = NetworkConditions()
        let store = self.store(network)
        defer { self.finish(store) }
        network.override(expensive: true, constrained: false)
        var failed = self.entry("f", bytes: self.large)
        failed.state = .failed(OutboxFailure(message: "no", retryable: true))
        #expect(store.hold(for: failed) == nil)
        network.override(expensive: false, constrained: false)
    }

    @Test func sendNowMarksTheEntryAndSyncsTheRow() {
        let network = NetworkConditions()
        let store = self.store(network)
        defer { self.finish(store) }
        network.override(expensive: true, constrained: false)
        store.injectOutboxEntry(self.entry("big", bytes: self.large))
        store.resyncOutboxHolds()
        let chat = store.chat(for: self.key)
        #expect(chat.items.first { $0.idempotencyKey == "big" }?.outboxHold == .expensive)

        chat.sendNow(outboxId: "big")
        #expect(store.outbox.entry(id: "big")?.sendOnAnyNetwork == true)
        store.resyncOutboxHolds()
        #expect(chat.items.first { $0.idempotencyKey == "big" }?.outboxHold == nil)
        network.override(expensive: false, constrained: false)
    }

    @Test func rowsResyncWhenTheNetworkChanges() {
        let network = NetworkConditions()
        let store = self.store(network)
        defer { self.finish(store) }
        store.injectOutboxEntry(self.entry("big", bytes: self.large))
        let chat = store.chat(for: self.key)
        store.resyncOutboxHolds()
        #expect(chat.items.first { $0.idempotencyKey == "big" }?.outboxHold == nil)
        network.override(expensive: false, constrained: true)
        store.resyncOutboxHolds()
        #expect(chat.items.first { $0.idempotencyKey == "big" }?.outboxHold == .constrained)
        network.override(expensive: false, constrained: false)
        store.resyncOutboxHolds()
        #expect(chat.items.first { $0.idempotencyKey == "big" }?.outboxHold == nil)
    }
}
