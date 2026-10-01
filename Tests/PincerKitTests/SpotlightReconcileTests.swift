import Foundation
import Testing
@testable import PincerKit

private actor GatedSpotlightIndexer: SpotlightIndexer {
    private var entries: [SpotlightEntry] = []
    private var deleteStarted: CheckedContinuation<Void, Never>?
    private var deleteRelease: CheckedContinuation<Void, Never>?

    func index(_ entries: [SpotlightEntry]) async { self.entries.append(contentsOf: entries) }

    func delete(ids: [String]) async {
        await withCheckedContinuation {
            self.deleteRelease = $0
            self.deleteStarted?.resume()
            self.deleteStarted = nil
        }
    }

    func deleteDomain(gatewayId: UUID) async {}

    func deleteAll() async { self.entries.removeAll() }

    func waitForDelete() async {
        if self.deleteRelease != nil { return }
        await withCheckedContinuation { self.deleteStarted = $0 }
    }

    func resumeDelete() {
        self.deleteRelease?.resume()
        self.deleteRelease = nil
    }

    func indexedEntries() -> [SpotlightEntry] { self.entries }
}

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

    @Test func sameTitleChatsAreDisambiguatedWithoutLeakingMessageText() {
        let gatewayA = UUID(), gatewayB = UUID()
        let key = "agent:main:dashboard:same-title"
        let rows = [Self.row(key, title: "Planning", at: 1)]
        let snippets = [key: "private message excerpt"]
        let personal = Spotlight.entries(gatewayId: gatewayA, gatewayName: "Personal", sessions: rows,
                                         cachedSnippets: snippets, includeMessages: false)[0]
        let work = Spotlight.entries(gatewayId: gatewayB, gatewayName: "Work", sessions: rows,
                                     cachedSnippets: snippets, includeMessages: false)[0]
        #expect(personal.title == work.title && personal.id != work.id)
        #expect(personal.contentDescription == "Personal" && work.contentDescription == "Work")
        #expect(personal.snippet == nil && work.snippet == nil)
        #expect(personal.contentDescription?.contains("private message excerpt") == false)

        let included = Spotlight.entries(gatewayId: gatewayA, gatewayName: "Personal", sessions: rows,
                                         cachedSnippets: snippets, includeMessages: true)[0]
        #expect(included.contentDescription == "Personal · private message excerpt")
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

    @Test func gatewayReindexIncludesProfileNameInTheDescription() async {
        let scratch = ScratchDefaults()
        let indexerA = FakeSpotlightIndexer(), indexerB = FakeSpotlightIndexer()
        let gatewayA = self.store(indexerA, defaults: scratch.defaults,
                                  profile: GatewayProfile(name: "Personal", url: "ws://127.0.0.1:1", authMode: .none))
        let gatewayB = self.store(indexerB, defaults: scratch.defaults,
                                  profile: GatewayProfile(name: "Work", url: "ws://127.0.0.1:2", authMode: .none))
        let key = "agent:main:dashboard:same-title"
        let row = Self.row(key, title: "Planning", at: 42)
        gatewayA.setSession(row, for: key)
        gatewayB.setSession(row, for: key)
        defer {
            SpotlightCenter.shared.forgetGateway(gatewayA.id)
            SpotlightCenter.shared.forgetGateway(gatewayB.id)
            scratch.remove()
        }

        await gatewayA.reindexSpotlight()
        await gatewayB.reindexSpotlight()
        #expect(indexerA.entries.first?.title == indexerB.entries.first?.title)
        #expect(indexerA.entries.first?.contentDescription == "Personal")
        #expect(indexerB.entries.first?.contentDescription == "Work")
    }

    @Test func firstReindexStillClearsUnknownGatewayResultsBeforeAddingCurrentChats() async {
        let scratch = ScratchDefaults()
        let indexer = FakeSpotlightIndexer()
        let gateway = self.store(indexer, defaults: scratch.defaults,
                                 profile: GatewayProfile(name: "Personal", url: "ws://127.0.0.1:1", authMode: .none))
        let stale = Spotlight.entries(gatewayId: gateway.id,
                                      sessions: [Self.row("agent:main:dashboard:removed", at: 1)],
                                      includeMessages: false)
        await indexer.index(stale)
        let currentKey = "agent:main:dashboard:current"
        gateway.setSession(Self.row(currentKey, at: 2), for: currentKey)
        defer {
            SpotlightCenter.shared.forgetGateway(gateway.id)
            scratch.remove()
        }

        await gateway.reindexSpotlight()
        #expect(indexer.entries.map(\.sessionKey) == [currentKey])
        #expect(Array(indexer.calls.suffix(2)) == ["domain", "index:1"])
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

    @Test func asyncReindexMustStillMatchMessageTextPrivacySetting() {
        let scratch = ScratchDefaults()
        #expect(Spotlight.canPublish(includeMessages: false, defaults: scratch.defaults))
        scratch.defaults.set(true, forKey: Spotlight.includeMessagesKey)
        #expect(!Spotlight.canPublish(includeMessages: false, defaults: scratch.defaults))
        #expect(Spotlight.canPublish(includeMessages: true, defaults: scratch.defaults))
        scratch.defaults.set(false, forKey: Spotlight.includeMessagesKey)
        #expect(!Spotlight.canPublish(includeMessages: true, defaults: scratch.defaults))
        #expect(Spotlight.canPublish(includeMessages: false, defaults: scratch.defaults))
        scratch.defaults.set(false, forKey: Spotlight.enabledKey)
        #expect(!Spotlight.canPublish(includeMessages: false, defaults: scratch.defaults))
        scratch.remove()
    }

    @Test func preferenceChangeDuringDeletionCannotPublishCachedMessageText() async {
        let scratch = ScratchDefaults()
        scratch.defaults.set(true, forKey: Spotlight.includeMessagesKey)
        let indexer = GatedSpotlightIndexer()
        let profile = GatewayProfile(name: "Personal", url: "ws://127.0.0.1:1", authMode: .none)
        let gateway = self.store(FakeSpotlightIndexer(), defaults: scratch.defaults, profile: profile)
        gateway.spotlightIndexer = indexer
        let currentKey = "agent:main:dashboard:privacy-race"
        let removedKey = "agent:main:dashboard:removed"
        let row = Self.row(currentKey, title: "After", at: 42)
        gateway.setSession(row, for: currentKey)
        let oldCurrent = Spotlight.entries(gatewayId: gateway.id, gatewayURL: profile.url,
                                           gatewayHost: gateway.gatewayHost, gatewayName: profile.name,
                                           sessions: [Self.row(currentKey, title: "Before", at: 42)],
                                           cachedSnippets: [currentKey: "private cached excerpt"],
                                           includeMessages: true)[0]
        let removed = Spotlight.entries(gatewayId: gateway.id, gatewayURL: profile.url,
                                        gatewayHost: gateway.gatewayHost, gatewayName: profile.name,
                                        sessions: [Self.row(removedKey, at: 1)], includeMessages: true)[0]
        let center = SpotlightCenter.shared
        center.sent[gateway.id] = [oldCurrent.id: oldCurrent, removed.id: removed]
        defer {
            center.sent.removeValue(forKey: gateway.id)
            center.overrides.removeValue(forKey: gateway.id)
            center.tasks.removeValue(forKey: gateway.id)?.cancel()
            scratch.remove()
        }

        let reindex = Task { await gateway.reindexSpotlight() }
        await indexer.waitForDelete()
        scratch.defaults.set(false, forKey: Spotlight.includeMessagesKey)
        await indexer.resumeDelete()
        await reindex.value

        let indexed = await indexer.indexedEntries()
        #expect(!indexed.contains { $0.snippet == "private cached excerpt" })
    }
}
}
