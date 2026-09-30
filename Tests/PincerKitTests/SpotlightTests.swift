import Foundation
import Testing
@testable import PincerKit

/// Spotlight suites share `SpotlightCenter.shared` (and one mutates the default indexer and
/// `UserDefaults.standard`), so they run one at a time.
@Suite(.serialized) enum SpotlightSuites {}

extension SpotlightSuites {
@Suite struct SpotlightTests {
    private let gateway = UUID()

    private func row(_ key: String, title: String? = nil, at ms: Double, extra: [String: JSONValue] = [:]) -> SessionRow {
        var fields: [String: JSONValue] = ["key": .string(key), "label": .string(title ?? key), "updatedAt": .number(ms)]
        for (k, v) in extra { fields[k] = v }
        return SessionRow(.object(fields))!
    }

    @Test func buildsNewestNonArchivedNonPlaceholderCapped() {
        let rows = [row("a", at: 1000), row("b", at: 3000), row("c", at: 2000),
                    row("old", at: 5000, extra: ["archived": .bool(true)]),
                    row("ph", at: 6000, extra: [SessionRow.placeholderField: .bool(true)])]
        let entries = Spotlight.entries(gatewayId: gateway, sessions: rows, includeMessages: false, cap: 2)
        #expect(entries.map(\.sessionKey) == ["b", "c"])
        #expect(entries[0].id.hasPrefix("pincer://open?"))
        #expect(entries[0].domainIdentifier == "gateway:\(gateway.uuidString)")
        #expect(PincerRoute.parse(URL(string: entries[0].id)!)?.sessionKey == "b")
    }

    @Test func snippetsOnlyWhenIncludingMessages() {
        let rows = [row("a", at: 1)]
        #expect(Spotlight.entries(gatewayId: gateway, sessions: rows, cachedSnippets: ["a": "hi"], includeMessages: false)[0].snippet == nil)
        #expect(Spotlight.entries(gatewayId: gateway, sessions: rows, cachedSnippets: ["a": "hi"], includeMessages: true)[0].snippet == "hi")
    }

    @Test func snippetTakesLastThreeTextMessagesAndCaps() {
        func item(_ n: Int, _ role: ChatRole, _ text: String) -> ChatItem {
            ChatItem(id: "\(n)", role: role, blocks: [.text(text)])
        }
        let items = [item(1, .user, "one"), item(2, .assistant, "two"), item(3, .toolResult, "tool"),
                     item(4, .user, "three"), item(5, .assistant, "four\n  five")]
        #expect(Spotlight.snippet(from: items) == "two · three · four five")
        let long = [item(1, .user, String(repeating: "x", count: 500))]
        #expect(Spotlight.snippet(from: long)?.count == 300)
        #expect(Spotlight.snippet(from: []) == nil)
    }

    @Test func fakeIndexerTracksCalls() async {
        let fake = FakeSpotlightIndexer()
        let entries = Spotlight.entries(gatewayId: gateway, sessions: [row("a", at: 1), row("b", at: 2)], includeMessages: false)
        await fake.index(entries)
        #expect(fake.ids.count == 2)
        await fake.delete(ids: [entries[0].id])
        #expect(fake.ids.count == 1)
        await fake.deleteDomain(gatewayId: gateway)
        #expect(fake.ids.isEmpty)
    }

    @Test func itemsNeverExpire() {
        #expect(Spotlight.expirationDate == .distantFuture)
    }

    @MainActor
    @Test func unchangedActivityReusesSnippetWithoutReadingCache() async {
        let scratch = ScratchDefaults()
        let temp = TempDir()
        scratch.defaults.set(true, forKey: Spotlight.includeMessagesKey)
        let id = UUID()
        let profile = GatewayProfile(id: id, name: "Mac", url: "ws://127.0.0.1:18789", authMode: .none)
        let store = GatewayStore(profile: profile, defaults: scratch.defaults, identity: Fixtures.identity())
        store.cacheRoot = temp.url
        let fake = FakeSpotlightIndexer()
        store.spotlightIndexer = fake
        defer { SpotlightCenter.shared.forgetGateway(id) }
        func snapshot(_ text: String) -> TranscriptCache.Snapshot {
            .init(items: [ChatItem(role: .user, blocks: [.text(text)])], complete: true)
        }
        func list(_ ms: Double) -> JSONValue {
            .object(["sessions": .array([.object(["key": .string("a"), "label": .string("A"), "updatedAt": .number(ms)])])])
        }
        await TranscriptCache.save(snapshot("first"), gatewayId: id, sessionKey: "a", root: temp.url)
        store.applySnapshot(list(1000))
        await store.reindexSpotlight()
        #expect(fake.entries.first?.snippet == "first")

        await TranscriptCache.save(snapshot("second"), gatewayId: id, sessionKey: "a", root: temp.url)
        await store.reindexSpotlight()
        #expect(fake.entries.first?.snippet == "first")

        store.applySnapshot(list(2000))
        await store.reindexSpotlight()
        #expect(fake.entries.first?.snippet == "second")
    }
}
}
