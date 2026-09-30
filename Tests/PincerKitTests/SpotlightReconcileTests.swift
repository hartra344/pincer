import Foundation
import Testing
@testable import PincerKit

/// #53: what goes into Spotlight, and when it leaves.
extension SpotlightSuites {
@MainActor
@Suite("Spotlight", .serialized)
struct SpotlightReconcileTests {
    let gatewayId = UUID()

    static func row(_ key: String, title: String? = nil, at: Int, archived: Bool = false, placeholder: Bool = false) -> SessionRow {
        var object: [String: JSONValue] = ["key": .string(key), "label": .string(title ?? key), "lastActivityAt": .number(Double(at))]
        if archived { object["archived"] = true }
        if placeholder { object[SessionRow.placeholderField] = true }
        return SessionRow(.object(object))!
    }

    func entries(_ rows: [SessionRow], snippets: [String: String] = [:], includeMessages: Bool = false, cap: Int = 200) -> [SpotlightEntry] {
        Spotlight.entries(gatewayId: self.gatewayId, sessions: rows, cachedSnippets: snippets, includeMessages: includeMessages, cap: cap)
    }

    @Test func excludesArchivedAndPlaceholders() {
        let result = self.entries([Self.row("agent:main:dashboard:a", at: 3000), Self.row("agent:main:dashboard:b", at: 2000, archived: true),
                                   Self.row("agent:main:dashboard:c", at: 1000, placeholder: true)])
        #expect(result.map(\.sessionKey) == ["agent:main:dashboard:a"])
    }

    @Test func newestFirstAndCapped() {
        let rows = (0..<10).map { Self.row("agent:main:dashboard:k\($0)", at: 1000 + $0) }
        let result = self.entries(rows, cap: 4)
        #expect(result.map(\.sessionKey) == ["agent:main:dashboard:k9", "agent:main:dashboard:k8", "agent:main:dashboard:k7", "agent:main:dashboard:k6"])
        #expect(self.entries(rows).count == 10)
        #expect(self.entries(rows, cap: 0).isEmpty)
    }

    @Test func identifierIsTheDeepLinkAndDomainIsTheGateway() {
        let entry = self.entries([Self.row("agent:main:dashboard:a", at: 1)])[0]
        #expect(entry.id.hasPrefix("pincer://open"))
        #expect(entry.id.contains("dashboard"))
        #expect(entry.domainIdentifier == "gateway:\(self.gatewayId.uuidString)")
    }

    @Test func snippetsOnlyWhenIncludingMessages() {
        let rows = [Self.row("agent:main:dashboard:a", at: 1)]
        let snippets = ["agent:main:dashboard:a": "hello there"]
        #expect(self.entries(rows, snippets: snippets, includeMessages: false)[0].snippet == nil)
        #expect(self.entries(rows, snippets: snippets, includeMessages: true)[0].snippet == "hello there")
    }

    @Test func snippetIsLastThreeTextMessagesCappedAt300() {
        func item(_ id: String, _ role: ChatRole, _ text: String) -> ChatItem {
            ChatItem(id: id, role: role, blocks: [.text(text)], timestamp: Date(timeIntervalSince1970: 1))
        }
        let items = [item("1", .user, "one"), item("2", .assistant, "  two \n words "), item("3", .user, "three"), item("4", .assistant, "four")]
        #expect(Spotlight.snippet(from: items) == "two words · three · four")
        let long = [item("1", .user, String(repeating: "x", count: 1000))]
        #expect(Spotlight.snippet(from: long)?.count == 300)
        #expect(Spotlight.snippet(from: []) == nil)
    }

    @Test func fakeIndexerTracksDeletes() async {
        let indexer = FakeSpotlightIndexer()
        let a = self.entries([Self.row("agent:main:dashboard:a", at: 1), Self.row("agent:main:dashboard:b", at: 2)])
        await indexer.index(a)
        #expect(indexer.ids.count == 2)
        await indexer.delete(ids: [a[0].id])
        #expect(indexer.ids.count == 1)
        await indexer.deleteAll()
        #expect(indexer.ids.isEmpty)
    }

    func store(_ indexer: FakeSpotlightIndexer, defaults: UserDefaults, profile: GatewayProfile) -> GatewayStore {
        let gateway = GatewayStore(profile: profile, defaults: defaults, identity: Fixtures.identity())
        gateway.spotlightIndexer = indexer
        return gateway
    }

    @Test func demoGatewayIsNeverIndexed() async {
        let scratch = ScratchDefaults()
        let indexer = FakeSpotlightIndexer()
        let gateway = self.store(indexer, defaults: scratch.defaults, profile: .demo())
        gateway.setSession(Self.row("agent:main:dashboard:a", at: 1), for: "agent:main:dashboard:a")
        await gateway.reindexSpotlight()
        #expect(indexer.ids.isEmpty && indexer.calls.isEmpty)
        scratch.remove()
    }

    @Test func reindexSendsOnlyChangesAndDeletesVanishedChats() async {
        let scratch = ScratchDefaults()
        let indexer = FakeSpotlightIndexer()
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = self.store(indexer, defaults: scratch.defaults, profile: profile)
        defer { SpotlightCenter.shared.forgetGateway(gateway.id); scratch.remove() }
        gateway.setSession(Self.row("agent:main:dashboard:a", at: 1), for: "agent:main:dashboard:a")
        gateway.setSession(Self.row("agent:main:dashboard:b", at: 2), for: "agent:main:dashboard:b")
        await gateway.reindexSpotlight()
        #expect(indexer.ids.count == 2)
        let before = indexer.calls.count
        await gateway.reindexSpotlight()
        #expect(indexer.calls.count == before, "unchanged chats aren't resent")
        gateway.setSession(nil, for: "agent:main:dashboard:b")
        await gateway.reindexSpotlight()
        #expect(indexer.ids.count == 1)
    }

    @Test func disabledDoesNotIndex() async {
        let scratch = ScratchDefaults()
        scratch.defaults.set(false, forKey: Spotlight.enabledKey)
        let indexer = FakeSpotlightIndexer()
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = self.store(indexer, defaults: scratch.defaults, profile: profile)
        defer { SpotlightCenter.shared.forgetGateway(gateway.id); scratch.remove() }
        gateway.setSession(Self.row("agent:main:dashboard:a", at: 1), for: "agent:main:dashboard:a")
        await gateway.reindexSpotlight()
        #expect(indexer.ids.isEmpty)
    }

    @Test func archivedChatLeavesTheIndexOnNextReindex() async {
        let scratch = ScratchDefaults()
        let indexer = FakeSpotlightIndexer()
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = self.store(indexer, defaults: scratch.defaults, profile: profile)
        defer { SpotlightCenter.shared.forgetGateway(gateway.id); scratch.remove() }
        let key = "agent:main:dashboard:a"
        gateway.setSession(Self.row(key, at: 1), for: key)
        await gateway.reindexSpotlight()
        #expect(indexer.ids.count == 1)
        gateway.setSession(Self.row(key, at: 1, archived: true), for: key)
        await gateway.reindexSpotlight()
        #expect(indexer.ids.isEmpty)
    }

    @Test func forgetTranscriptDeletesItsSpotlightId() async {
        let scratch = ScratchDefaults()
        let indexer = FakeSpotlightIndexer()
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = self.store(indexer, defaults: scratch.defaults, profile: profile)
        defer { SpotlightCenter.shared.forgetGateway(gateway.id); scratch.remove() }
        let keep = "agent:main:dashboard:keep", drop = "agent:main:dashboard:drop"
        gateway.setSession(Self.row(keep, at: 1), for: keep)
        gateway.setSession(Self.row(drop, at: 2), for: drop)
        await gateway.reindexSpotlight()
        await gateway.forgetTranscript(drop)
        #expect(indexer.entries.map(\.sessionKey) == [keep])
    }

    @Test func messageTextComesFromTheLocalCacheOnlyWhenIncluded() async {
        let scratch = ScratchDefaults()
        let temp = TempDir()
        let indexer = FakeSpotlightIndexer()
        let profile = GatewayProfile(name: "T", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = self.store(indexer, defaults: scratch.defaults, profile: profile)
        gateway.cacheRoot = temp.url
        defer { SpotlightCenter.shared.forgetGateway(gateway.id); scratch.remove() }
        let key = "agent:main:dashboard:a"
        gateway.setSession(Self.row(key, at: 1), for: key)
        let item = ChatItem(id: "m", role: .user, blocks: [.text("ramen plans")], timestamp: Date(timeIntervalSince1970: 1))
        await TranscriptCache.save(TranscriptCache.Snapshot(items: [item], complete: true), gatewayId: gateway.id, sessionKey: key, root: temp.url)
        await gateway.reindexSpotlight()
        #expect(indexer.entries.first?.snippet == nil)
        scratch.defaults.set(true, forKey: Spotlight.includeMessagesKey)
        SpotlightCenter.shared.sent.removeValue(forKey: gateway.id)
        await gateway.reindexSpotlight()
        #expect(indexer.entries.first?.snippet == "ramen plans")
        await TranscriptCache.shutdown(root: temp.url)
        temp.remove()
    }

    @Test func turningSpotlightOffDeletesEverything() async {
        let scratch = ScratchDefaults()
        let center = SpotlightCenter.shared
        let previous = center.defaultIndexer
        let indexer = FakeSpotlightIndexer()
        center.defaultIndexer = indexer
        let saved = UserDefaults.standard.object(forKey: Spotlight.enabledKey)
        defer {
            center.defaultIndexer = previous
            if let saved { UserDefaults.standard.set(saved, forKey: Spotlight.enabledKey) } else { UserDefaults.standard.removeObject(forKey: Spotlight.enabledKey) }
            scratch.remove()
        }
        await indexer.index(self.entries([Self.row("agent:main:dashboard:a", at: 1)]))
        UserDefaults.standard.set(false, forKey: Spotlight.enabledKey)
        AppModel(defaults: scratch.defaults).spotlightPreferencesChanged()
        for _ in 0..<200 where !indexer.ids.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(indexer.ids.isEmpty && indexer.calls.contains("all"))
    }

    @Test func defaultsAreOnAndMessagesOff() {
        let scratch = ScratchDefaults()
        #expect(Spotlight.isEnabled(scratch.defaults))
        #expect(!Spotlight.includesMessages(scratch.defaults))
        scratch.remove()
    }
}
}
