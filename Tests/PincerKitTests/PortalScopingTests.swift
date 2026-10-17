import Foundation
import Testing
@testable import PincerKit

// #1029: portals are scoped to the chat's agent. Attributed portals come from the chat's own `portal`
// tool calls; owned portals come from `portal.session.list` when the Gateway advertises it.

private func portalEntry(id: String, title: String = "T", port: Int = 4173, createdAtMs: Int = 1000) -> JSONValue {
    Fixtures.json(#"{"id":"\#(id)","title":"\#(title)","port":\#(port),"listenPort":\#(port),"publicUrl":"https://portal.test:\#(port)/","createdAtMs":\#(createdAtMs),"url":"https://portal.test:\#(port)/?openclaw_portal=t","tokenQuery":"openclaw_portal=t"}"#)
}

private func openResult(id: String = "clock", publicUrl: String = "https://portal.test:4173/") -> String {
    let json = #"{"id":"\#(id)","title":"Studio clock","port":4173,"listenPort":4173,"publicUrl":"\#(publicUrl)","createdAtMs":1000}"#
    return "Portal route allocated at \(publicUrl)\n\(json)"
}

private func portalCall(args: String? = #"{"action":"open","port":4173}"#, result: String? = openResult(), isError: Bool = false,
                        running: Bool = false, name: String = "portal") -> ToolActivity {
    ToolActivity(id: "c1", name: name, arguments: args, result: result, isError: isError, isRunning: running)
}

struct PortalToolOpenTests {
    @Test func idComesFromTheJSONBlockAfterTheTextPrefix() {
        let open = portalCall().openedPortal
        #expect(open?.id == "clock")
        #expect(open?.publicURL == "https://portal.test:4173/")
    }

    @Test func aBarePublicURLStillIdentifiesThePortal() {
        let open = portalCall(result: #"{"publicUrl":"https://portal.test:4999/","title":"x"}"#).openedPortal
        #expect(open != nil && open?.id == nil && open?.publicURL == "https://portal.test:4999/")
    }

    @Test func nonOpenOrFailedCallsAreIgnored() {
        #expect(portalCall(isError: true).openedPortal == nil)
        #expect(portalCall(running: true).openedPortal == nil)
        #expect(portalCall(args: #"{"action":"list"}"#, result: #"{"portals":[{"id":"clock"}]}"#).openedPortal == nil)
        #expect(portalCall(args: #"{"action":"close","id":"clock"}"#, result: #"{"id":"clock","closed":true}"#).openedPortal == nil)
        #expect(portalCall(name: "browser").openedPortal == nil)
        #expect(portalCall(result: nil).openedPortal == nil)
        #expect(portalCall(args: nil).openedPortal == nil)
        #expect(portalCall(result: "Nothing useful").openedPortal == nil)
    }

    @Test func aHugeResultIsCapped() {
        // The id sits past the scan cap, so it is not found; the scan stays bounded.
        let filler = String(repeating: "x", count: 200_000)
        let late = portalCall(result: "\(filler)\n" + #"{"id":"late","publicUrl":"https://portal.test:1/"}"#)
        #expect(late.openedPortal == nil)
        let early = portalCall(result: openResult() + "\n" + filler)
        #expect(early.openedPortal?.id == "clock")
    }

    @Test func itParticipatesInEquality() {
        let a = portalCall()
        var b = portalCall()
        #expect(a == b && a.hashValue == b.hashValue)
        b.result = openResult(id: "other")
        #expect(a != b)
    }
}

private final class WriteCounter: @unchecked Sendable { var value = 0 }

@MainActor
struct ChatStoreOpenedPortalsTests {
    private func makeChat() -> (ChatStore, GatewayStore, ScratchDefaults) {
        let scratch = ScratchDefaults()
        let gateway = GatewayStore(profile: GatewayProfile(id: UUID(), name: "Portals", url: "ws://127.0.0.1:1", authMode: .none),
                                   defaults: scratch.defaults, identity: Fixtures.identity())
        gateway.cacheRoot = nil
        gateway.outboxRoot = nil
        let chat = ChatStore(sessionKey: "agent:main:portal-chat", agentId: "main", gateway: gateway, headless: false)
        return (chat, gateway, scratch)
    }

    private func turn(_ id: String, call: String, args: String, result: String) -> [ChatItem] {
        var out = ChatItem(id: "r-\(id)", role: .toolResult, blocks: [.text(result)])
        out.toolCallId = call
        return [ChatItem(id: "a-\(id)", role: .assistant, blocks: [.toolCall(id: call, name: "portal", arguments: args)]), out]
    }

    @Test func committedOpenCallsAreCollected() {
        let (chat, gateway, scratch) = makeChat()
        defer { gateway.stop(); scratch.remove() }
        #expect(chat.openedPortals == PortalRefs())
        chat.items = turn("1", call: "c1", args: #"{"action":"open","port":4173}"#, result: openResult())
        #expect(chat.openedPortals.ids == ["clock"])
        #expect(chat.openedPortals.publicURLs.count == 1 && chat.openedPortals.publicURLs.first?.hasPrefix("https://portal.test:4173") == true)
    }

    @Test func theLiveRunsOpenCallCounts() {
        let (chat, gateway, scratch) = makeChat()
        defer { gateway.stop(); scratch.remove() }
        var live = LiveRun(runId: "run-1")
        live.tools = [ToolActivity(id: "c9", name: "portal", arguments: #"{"action":"open","port":4173}"#, result: openResult(id: "live"),
                                   isError: false, isRunning: false)]
        chat.live = live
        chat.rebuild(itemsChanged: false)
        #expect(chat.openedPortals.ids == ["live"])
    }

    @Test func itOnlyChangesOnATransition() {
        let (chat, gateway, scratch) = makeChat()
        defer { gateway.stop(); scratch.remove() }
        let counter = WriteCounter()
        chat.items = turn("1", call: "c1", args: #"{"action":"open","port":4173}"#, result: openResult())
        let before = chat.openedPortals
        withObservationTracking({ _ = chat.openedPortals }, onChange: { counter.value += 1 })
        // Unrelated message: the derived value is equal, so nothing is written.
        chat.items.append(ChatItem(id: "u2", role: .user, blocks: [.text("thanks")]))
        #expect(chat.openedPortals == before && counter.value == 0)
        // A streamed token on a live run doesn't touch it either.
        var live = LiveRun(runId: "run-2")
        live.text = "hello"
        chat.live = live
        chat.rebuild(itemsChanged: false)
        live.text += " world"
        chat.live = live
        chat.rebuild(itemsChanged: false)
        #expect(counter.value == 0)
        // A genuinely new portal is a transition.
        chat.items += turn("3", call: "c3", args: #"{"action":"open","port":4174}"#, result: openResult(id: "board", publicUrl: "https://portal.test:4174/"))
        #expect(chat.openedPortals.ids == ["clock", "board"])
        #expect(counter.value == 1)
    }
}

private actor FakeScopedGateway {
    var global: [JSONValue]
    var owned: [String: [JSONValue]] = [:]
    var environments: [String: String?] = [:]
    var closed = false
    private(set) var calls: [(method: String, params: JSONValue)] = []

    init(global: [JSONValue]) { self.global = global }
    func setOwned(_ sessionKey: String, env: String?, _ portals: [JSONValue]) { owned[sessionKey] = portals; environments[sessionKey] = .some(env) }
    func setGlobal(_ list: [JSONValue]) { global = list }
    func count(_ method: String) -> Int { calls.filter { $0.method == method }.count }
    func params(_ method: String) -> [JSONValue] { calls.filter { $0.method == method }.map(\.params) }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        calls.append((method, params))
        switch method {
        case "portal.list":
            return ["portals": .array(global)]
        case "portal.close":
            let id = params["id"]?.string
            global.removeAll { $0["id"]?.string == id }
            return ["closed": true]
        case "environments.session.status":
            let key = params["sessionKey"]?.string ?? ""
            guard let env = environments[key], let env else { return ["attachment": .null, "closed": false] }
            return ["attachment": ["environmentId": .string(env), "closedAtMs": .null], "closed": false]
        case "portal.session.list":
            let key = params["sessionKey"]?.string ?? ""
            return ["portals": .array(owned[key] ?? [])]
        case "portal.session.close":
            let key = params["sessionKey"]?.string ?? ""
            let id = params["id"]?.string
            owned[key]?.removeAll { $0["id"]?.string == id }
            return ["closed": true]
        default:
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "unknown method", details: nil)
        }
    }
}

@MainActor
struct PortalScopingTests {
    private static let allMethods: Set<String> = ["portal.list", "portal.close", "environments.session.status", "portal.session.list", "portal.session.close"]
    private static let legacyMethods: Set<String> = ["portal.list", "portal.close"]

    private let clock = portalEntry(id: "clock", title: "Studio clock", port: 4173, createdAtMs: 10)
    private let board = portalEntry(id: "board", title: "Build dashboard", port: 4174, createdAtMs: 20)
    private let docs = portalEntry(id: "docs", title: "Docs", port: 4175, createdAtMs: 5)

    private func makeStore(_ fake: FakeScopedGateway, methods: Set<String>? = PortalScopingTests.allMethods) -> PortalStore {
        PortalStore(request: { try await fake.request($0, $1) }, methods: { methods }, debounce: .milliseconds(30))
    }

    private func scope(_ key: String, agent: String? = "main", ids: Set<String> = [], refs: PortalRefs? = nil) -> PortalScope {
        PortalScope(sessionKey: key, agentId: agent, opened: refs ?? PortalRefs(ids: ids))
    }

    @Test func aChatSeesOnlyThePortalsItOpened() async {
        let fake = FakeScopedGateway(global: [clock, board])
        let store = makeStore(fake, methods: Self.legacyMethods)
        await store.refresh()
        #expect(store.portals(for: scope("A", ids: ["clock"])).map(\.id) == ["clock"])
        #expect(store.portals(for: scope("B")).isEmpty)
        #expect(store.portals(for: scope("B", ids: ["board"])).map(\.id) == ["board"])
    }

    @Test func thePublicURLIsTheFallbackMatch() async {
        let fake = FakeScopedGateway(global: [clock, board])
        let store = makeStore(fake, methods: Self.legacyMethods)
        await store.refresh()
        #expect(store.portals(for: scope("A", refs: PortalRefs(tools: [portalCall(result: openResult(id: "", publicUrl: "https://portal.test:4174/"))]))).map(\.id) == ["board"])
    }

    @Test func portalsMatchedByNeitherShowNowhere() async {
        let fake = FakeScopedGateway(global: [clock, board])
        let store = makeStore(fake)
        await store.refresh()
        await store.refreshOwned(sessionKey: "A", agentId: "main")
        #expect(store.portals(for: scope("A", ids: ["ghost"])).isEmpty)
    }

    @Test func ownedPortalsComeFromTheSessionMethodsAndOnlyShowInThatSession() async {
        let fake = FakeScopedGateway(global: [clock])
        await fake.setOwned("A", env: "env-1", [board])
        let store = makeStore(fake)
        await store.refresh()
        await store.refreshOwned(sessionKey: "A", agentId: "main")
        #expect(store.portals(for: scope("A")).map(\.id) == ["board"])
        #expect(store.portals(for: scope("B")).isEmpty)
        let list = await fake.params("portal.session.list")
        #expect(list.count == 1)
        #expect(list.first?["sessionKey"]?.string == "A" && list.first?["agentId"]?.string == "main" && list.first?["environmentId"]?.string == "env-1")
    }

    @Test func ownedAndAttributedAreMergedDedupedAndOrdered() async {
        let fake = FakeScopedGateway(global: [clock, board, docs])
        await fake.setOwned("A", env: "env-1", [board])
        let store = makeStore(fake)
        await store.refresh()
        await store.refreshOwned(sessionKey: "A", agentId: "main")
        // board is both owned and attributed: shown once; the union is ordered by createdAtMs.
        let ids = store.portals(for: scope("A", ids: ["board", "clock", "docs"])).map(\.id)
        #expect(ids == ["docs", "clock", "board"])
    }

    @Test func withoutTheSessionMethodsOnlyAttributedPortalsShow() async {
        let fake = FakeScopedGateway(global: [clock])
        await fake.setOwned("A", env: "env-1", [board])
        let store = makeStore(fake, methods: Self.legacyMethods)
        await store.refresh()
        await store.refreshOwned(sessionKey: "A", agentId: "main")
        let probes = await fake.count("environments.session.status") + fake.count("portal.session.list")
        #expect(probes == 0)
        #expect(store.portals(for: scope("A", ids: ["clock"])).map(\.id) == ["clock"])
    }

    @Test func noAttachmentMeansNoOwnedPortals() async {
        let fake = FakeScopedGateway(global: [])
        await fake.setOwned("A", env: nil, [board])
        let store = makeStore(fake)
        await store.refresh()
        await store.refreshOwned(sessionKey: "A", agentId: "main")
        #expect(store.portals(for: scope("A")).isEmpty)
        #expect(await fake.count("portal.session.list") == 0)
    }

    @Test func aFailingSessionListIsEmptyWithoutRetrying() async {
        let store = PortalStore(request: { method, _ in
            switch method {
            case "portal.list": return ["portals": .array([])]
            case "environments.session.status": return Fixtures.json(#"{"attachment":{"environmentId":"e","closedAtMs":null},"closed":false}"#)
            default: throw GatewayError.rpc(code: "UNAVAILABLE", message: "no", details: nil)
            }
        }, methods: { Self.allMethods })
        await store.refresh()
        await store.refreshOwned(sessionKey: "A", agentId: "main")
        #expect(store.portals(for: scope("A")).isEmpty && !store.unavailable)
    }

    @Test func aClosedAttachmentMeansNoOwnedPortals() async {
        let store = PortalStore(request: { method, _ in
            switch method {
            case "portal.list": return ["portals": .array([])]
            case "environments.session.status": return Fixtures.json(#"{"attachment":{"environmentId":"e","closedAtMs":5},"closed":true}"#)
            default: return ["portals": .array([portalEntry(id: "x")])]
            }
        }, methods: { Self.allMethods })
        await store.refresh()
        await store.refreshOwned(sessionKey: "A", agentId: "main")
        #expect(store.portals(for: scope("A")).isEmpty)
    }

    @Test func closingAnOwnedPortalUsesTheSessionMethod() async {
        let fake = FakeScopedGateway(global: [clock])
        await fake.setOwned("A", env: "env-1", [board])
        let store = makeStore(fake)
        await store.refresh()
        await store.refreshOwned(sessionKey: "A", agentId: "main")
        let s = scope("A")
        #expect(await store.close("board", scope: s))
        let closes = await fake.params("portal.session.close")
        #expect(closes.count == 1)
        #expect(closes.first?["id"]?.string == "board" && closes.first?["sessionKey"]?.string == "A"
            && closes.first?["agentId"]?.string == "main" && closes.first?["environmentId"]?.string == "env-1")
        #expect(await fake.count("portal.close") == 0)
        #expect(store.portals(for: s).isEmpty)
    }

    @Test func closingAnAttributedPortalUsesPortalClose() async {
        let fake = FakeScopedGateway(global: [clock])
        let store = makeStore(fake)
        await store.refresh()
        let s = scope("A", ids: ["clock"])
        #expect(await store.close("clock", scope: s))
        #expect(await fake.params("portal.close").first?["id"]?.string == "clock")
        #expect(await fake.count("portal.session.close") == 0)
        #expect(store.portals(for: s).isEmpty)
    }

    @Test func reconnectClearsTheOwnedCache() async {
        let fake = FakeScopedGateway(global: [])
        await fake.setOwned("A", env: "env-1", [board])
        let store = makeStore(fake)
        await store.refresh()
        await store.refreshOwned(sessionKey: "A", agentId: "main")
        #expect(store.portals(for: scope("A")).count == 1)
        store.handleReconnect()
        #expect(store.portals(for: scope("A")).isEmpty)
    }

    @Test func theOwnedCacheIsBoundedAtThirtyTwoSessions() async {
        let fake = FakeScopedGateway(global: [])
        for i in 0..<40 { await fake.setOwned("S\(i)", env: "e\(i)", [portalEntry(id: "p\(i)", port: 5000 + i)]) }
        let store = makeStore(fake)
        await store.refresh()
        for i in 0..<40 { await store.refreshOwned(sessionKey: "S\(i)", agentId: "main") }
        let kept = (0..<40).filter { !store.portals(for: scope("S\($0)")).isEmpty }
        #expect(kept.count == 32)
        #expect(kept.first == 8 && kept.last == 39)
    }

    @Test func aTrackedSessionRefetchesOnChangeAndOthersDoNot() async {
        let fake = FakeScopedGateway(global: [])
        await fake.setOwned("A", env: "env-1", [])
        let store = makeStore(fake)
        await store.refresh()
        store.trackOwned(sessionKey: "A", agentId: "main")
        _ = await portalWait { await fake.count("portal.session.list") >= 1 }
        await fake.setOwned("A", env: "env-1", [board])
        store.handle(event: "portal.changed")
        #expect(await portalWait { !store.portals(for: scope("A")).isEmpty })
        // A session that was never tracked or refreshed is not re-fetched.
        let before = await fake.params("portal.session.list").filter { $0["sessionKey"]?.string == "Z" }.count
        store.handle(event: "portal.changed")
        try? await Task.sleep(for: .milliseconds(200))
        let after = await fake.params("portal.session.list").filter { $0["sessionKey"]?.string == "Z" }.count
        #expect(before == 0 && after == 0)
        store.untrackOwned(sessionKey: "A")
    }

    @Test func scopingFiftyPortalsStaysWithinBudget() async {
        let fake = FakeScopedGateway(global: (0..<50).map { portalEntry(id: "p\($0)", port: 6000 + $0, createdAtMs: $0) })
        let store = makeStore(fake, methods: Self.legacyMethods)
        await store.refresh()
        let s = scope("A", ids: Set((0..<25).map { "p\($0)" }))
        var total = 0
        let elapsed = ContinuousClock().measure {
            for _ in 0..<1000 { total += store.portals(for: s).count }
        }
        #expect(total == 25_000)
        #expect(elapsed < PerfBudget.limit(.milliseconds(400)), "portals(for:) took \(elapsed)")
    }

    @Test func derivingOpenedPortalsFromALargeTranscriptStaysWithinBudget() {
        var refs = PortalRefs()
        let elapsed = ContinuousClock().measure {
            let tools = (0..<2000).map { i in
                ToolActivity(id: "c\(i)", name: i % 10 == 0 ? "portal" : "exec", arguments: i % 10 == 0 ? #"{"action":"open","port":4173}"# : #"{"command":"ls"}"#,
                             result: i % 10 == 0 ? openResult(id: "p\(i)") : String(repeating: "x", count: 2000), isError: false, isRunning: false)
            }
            refs = PortalRefs(tools: tools)
        }
        #expect(refs.ids.count == 200)
        #expect(elapsed < PerfBudget.limit(.milliseconds(250)), "openedPortal derivation took \(elapsed)")
    }
}

@MainActor
private func portalWait(_ timeout: Double = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
