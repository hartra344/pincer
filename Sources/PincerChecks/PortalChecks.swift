import Foundation
@testable import PincerKit

// Portals in the workspace panel (#974 PR 2): the origin policy and parsing (offline), the demo's
// "Studio clock" portal, and the real mock Gateway with its tiny HTTP server behind the access token.

private func portalValue(publicUrl: String, url: String? = nil, id: String = "p") -> JSONValue {
    var object: [String: JSONValue] = ["id": .string(id), "title": "T", "port": 1, "listenPort": 1, "publicUrl": .string(publicUrl), "createdAtMs": 1]
    if let url { object["url"] = .string(url) }
    return .object(object)
}

@MainActor
func runPortalOfflineChecks() {
    let portal = PortalSummary.parse(portalValue(publicUrl: "https://portal.test:4173/", url: "https://portal.test:4173/?openclaw_portal=secret"))!
    func allows(_ s: String, main: Bool = true) -> Bool { URL(string: s).map { PortalOriginPolicy.allows($0, portal: portal, isMainFrame: main) } ?? false }
    check(allows("https://portal.test:4173/x?y=1") && allows("https://PORTAL.test:4173/"), "portal policy: the portal's own origin is allowed")
    check(!allows("https://portal.test:4174/") && !allows("http://portal.test:4173/") && !allows("https://other.test:4173/"),
          "portal policy: another port, scheme or host is refused")
    check(!allows("https://portal.test:4173@evil.test/") && !allows("https://user:pw@portal.test:4173/"), "portal policy: userinfo tricks are refused")
    check(["pincer://x", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x"].allSatisfy { !allows($0) },
          "portal policy: pincer, javascript, file and data URLs are refused")
    check(allows("about:blank", main: false) && allows("about:srcdoc", main: false) && !allows("about:blank") && !allows("about:srcdoc"),
          "portal policy: about:blank and about:srcdoc only in subframes")
    check(!allows("https://portal.test.:4173/") && allows("https://Portal.TEST:4173/"), "portal policy: a trailing-dot host is denied, case is normalised")
    let alias = PortalSummary.parse(portalValue(publicUrl: "http://127.0.0.1:8080/"))!
    check(["http://localhost:8080/", "http://[::1]:8080/"].allSatisfy { !PortalOriginPolicy.allows(URL(string: $0)!, portal: alias) },
          "portal policy: loopback aliases are different origins")
    check(!allows("http://evil.test#@portal.test:4173/") && !allows("https://xn--portl-cpe.test:4173/"),
          "portal policy: fragment-@ and punycode homograph tricks are refused")
    func external(_ s: String) -> String? { URL(string: s).flatMap(PortalOriginPolicy.externalURL(for:))?.absoluteString }
    check(external("https://a.test/x?openclaw_portal=secret&y=1") == "https://a.test/x?y=1" && external("https://u:p@a.test/") == nil
          && ["pincer://x", "mailto:a@b.test", "tel:1", "javascript:x", "file:///x", "data:text/html,x"].allSatisfy { external($0) == nil },
          "portal policy: only token-free http(s) links go to the system browser")
    let defaults = PortalSummary.parse(portalValue(publicUrl: "https://a.test/"))!
    check(PortalOriginPolicy.allows(URL(string: "https://a.test:443/")!, portal: defaults), "portal policy: default ports are normalised")
    check(PortalOriginPolicy.strippedForDisplay(URL(string: "https://a.test/p?x=1&openclaw_portal=secret")!).absoluteString == "https://a.test/p?x=1",
          "portal: the access token is stripped for display")
    check(portal.displayURL.absoluteString == "https://portal.test:4173/" && portal.loadURL != nil, "portal: the display URL has no token, the load URL does")
    let demoValue = portalValue(publicUrl: "demo-portal://studio-clock/", url: "demo-portal://studio-clock/?openclaw_portal=demo")
    check(PortalSummary.parse(demoValue) == nil && PortalSummary.parse(demoValue, allowsDemoScheme: true) != nil,
          "portal: the demo scheme is parsed only for the demo gateway")
    check(PortalSummary.parse(portalValue(publicUrl: "javascript:alert(1)")) == nil && PortalSummary.parse(.string("x")) == nil,
          "portal: junk entries are dropped")
    check(PortalSummary.parse(portalValue(publicUrl: "https://portal.test:4173/", url: "https://evil.test/?openclaw_portal=s"))?.loadURL == nil,
          "portal: an access link on another origin is ignored")
}

/// #1029: a chat shows only the portals its agent opened (its own `portal` tool calls) and those its session owns.
@MainActor
func runPortalScopingOfflineChecks() async {
    func open(_ id: String, _ url: String, args: String = #"{"action":"open","port":4173}"#, error: Bool = false, running: Bool = false) -> ToolActivity {
        let json = #"{"id":"\#(id)","title":"T","port":4173,"listenPort":4173,"publicUrl":"\#(url)","createdAtMs":1}"#
        return ToolActivity(id: "c-\(id)", name: "portal", arguments: args, result: "Portal route allocated at \(url)\n\(json)", isError: error, isRunning: running)
    }
    let tool = open("clock", "https://portal.test:4173/")
    check(tool.openedPortal?.id == "clock" && tool.openedPortal?.publicURL == "https://portal.test:4173/",
          "portal scoping: a portal open call yields the id and public URL from the JSON after the text prefix")
    check(open("a", "https://a.test/", error: true).openedPortal == nil && open("a", "https://a.test/", running: true).openedPortal == nil
          && open("a", "https://a.test/", args: #"{"action":"list"}"#).openedPortal == nil
          && open("a", "https://a.test/", args: #"{"action":"close","id":"a"}"#).openedPortal == nil,
          "portal scoping: failed, running, list and close calls are ignored")
    let filler = String(repeating: "x", count: 100_000)
    let late = ToolActivity(id: "late", name: "portal", arguments: #"{"action":"open"}"#, result: filler + #"{"id":"late","publicUrl":"https://l.test/"}"#,
                            isError: false, isRunning: false)
    check(late.openedPortal == nil, "portal scoping: a huge result is only scanned up to a cap")

    // #1042: Tool Search hides `portal` behind `dispatch_action`; CLI harnesses prefix the name.
    let clockSummary = #"{"id":"portal_studio_clock","title":"Studio clock","port":4173,"publicUrl":"https://portal.test:4173/","createdAtMs":1}"#
    func envelope(_ summary: String?, tool: String = "portal") -> String {
        var content: [JSONValue] = [["type": "text", "text": "Portal route allocated at https://portal.test:4173/. Use the returned URLs unchanged."]]
        if let summary { content.append(["type": "text", "text": .string(summary)]) }
        let object: JSONValue = ["tool": ["id": .string("openclaw:core:\(tool)"), "name": .string(tool), "source": "openclaw"], "result": ["content": .array(content)]]
        return ContentBlock.prettyJSON(object) ?? ""
    }
    func dispatched(_ arguments: String, _ result: String, name: String = "dispatch_action", error: Bool = false) -> ToolActivity {
        ToolActivity(id: "d1", name: name, arguments: arguments, result: result, isError: error, isRunning: false)
    }
    let viaEnvelope = dispatched(#"{"id":"openclaw:core:portal","args":{"action":"open","port":4173}}"#, envelope(clockSummary))
    check(viaEnvelope.openedPortal?.id == "portal_studio_clock" && viaEnvelope.openedPortal?.publicURL == "https://portal.test:4173/",
          "portal scoping: a dispatch_action portal open yields the summary id and public URL, not the envelope's tool id")
    check(dispatched(#"{"id":"portal","input":{"action":"open","port":4173}}"#, envelope(clockSummary)).openedPortal?.id == "portal_studio_clock"
          && dispatched(#"{"id":"openclaw:core:portal","action":"open","port":4173}"#, envelope(clockSummary)).openedPortal?.id == "portal_studio_clock"
          && dispatched(#"{"id":"openclaw:core:portal","args":{"action":"open"}}"#, envelope(clockSummary), name: "tool_call").openedPortal?.id == "portal_studio_clock",
          "portal scoping: dispatch_action with the bare id, input, flattened arguments, or the legacy tool_call name still counts")
    check(dispatched(#"{"id":"openclaw:core:portal","args":{"action":"open"}}"#, envelope(nil)).openedPortal == nil,
          "portal scoping: a dispatch_action envelope without a summary never yields the envelope's tool id")
    check(dispatched(#"{"id":"openclaw:core:web_fetch","args":{"action":"open"}}"#, envelope(#"{"id":"page","publicUrl":"https://e.test/"}"#, tool: "web_fetch")).openedPortal == nil
          && dispatched(#"{"id":"openclaw:core:portal","args":{"action":"list"}}"#, envelope(clockSummary)).openedPortal == nil
          && dispatched(#"{"id":"openclaw:core:portal","args":{"action":"open"}}"#, envelope(clockSummary), error: true).openedPortal == nil,
          "portal scoping: dispatch_action wrapping another tool, a list call, or a failed call is ignored")
    let mcpText = "Portal route allocated at https://portal.test:4173/\n" + clockSummary
    check(["mcp__openclaw__portal", "mcp_openclaw_portal"].allSatisfy {
        ToolActivity(id: "m", name: $0, arguments: #"{"action":"open","port":4173}"#, result: mcpText, isError: false, isRunning: false).openedPortal?.id == "portal_studio_clock"
    }, "portal scoping: the MCP-prefixed portal names (mcp__openclaw__portal, mcp_openclaw_portal) count")

    func entry(_ id: String, port: Int, at: Int) -> JSONValue {
        .object(["id": .string(id), "title": .string(id), "port": .number(Double(port)), "listenPort": .number(Double(port)),
                 "publicUrl": .string("https://portal.test:\(port)/"), "createdAtMs": .number(Double(at))])
    }
    let global: [JSONValue] = [entry("clock", port: 4173, at: 1), entry("board", port: 4174, at: 2)]
    let ownedBoard: [JSONValue] = [entry("board", port: 4174, at: 2)]
    let calls = Counter()
    func store(methods: Set<String>) -> PortalStore {
        PortalStore(request: { method, params in
            await calls.bump(method)
            switch method {
            case "portal.list": return ["portals": .array(global)]
            case "environments.session.status":
                return params["sessionKey"]?.string == "A" ? ["attachment": ["environmentId": "env-1", "closedAtMs": .null], "closed": false] : ["attachment": .null]
            case "portal.session.list": return ["portals": .array(params["sessionKey"]?.string == "A" ? ownedBoard : [])]
            default: return ["closed": true]
            }
        }, methods: { methods }, debounce: .milliseconds(20))
    }
    let all: Set<String> = ["portal.list", "portal.close", "environments.session.status", "portal.session.list", "portal.session.close"]
    let scoped = store(methods: all)
    await scoped.refresh()
    await scoped.refreshOwned(sessionKey: "A", agentId: "main")
    await scoped.refreshOwned(sessionKey: "B", agentId: "other")
    func scope(_ key: String, _ tools: [ToolActivity] = []) -> PortalScope {
        PortalScope(sessionKey: key, agentId: key == "B" ? "other" : "main", opened: PortalRefs(tools: tools))
    }
    check(scoped.portals(for: scope("A", [tool])).map(\.id) == ["clock", "board"], "portal scoping: a chat shows its attributed and owned portals")
    check(scoped.portals(for: scope("B")).isEmpty, "portal scoping: another chat shows neither")
    check(scoped.portals(for: scope("C", [tool])).map(\.id) == ["clock", "board"], "portal scoping: another chat of the same agent shows its attributed and owned portals")
    // Per agent: once a chat of agent "main" opened it, any other chat of that agent shows it, even with an empty transcript.
    scoped.recordOpened(PortalRefs(tools: [tool]), agentId: "main", sessionKey: "A")
    check(scoped.portals(for: scope("C")).map(\.id) == ["clock", "board"],
          "portal scoping: another chat of the same agent shows the portal the agent opened")
    check(scoped.portals(for: scope("B")).isEmpty && scoped.attributedAgent(for: PortalSummary.parse(global[0])!) == "main",
          "portal scoping: a chat of another agent still shows none, and the portal is attributed to its agent")
    let legacy = store(methods: ["portal.list", "portal.close"])
    await legacy.refresh()
    await legacy.refreshOwned(sessionKey: "A", agentId: "main")
    check(legacy.portals(for: scope("A")).isEmpty && legacy.portals(for: scope("A", [tool])).map(\.id) == ["clock"],
          "portal scoping: without the session methods only attributed portals show")
    let statusCalls = await calls.count("environments.session.status")
    check(statusCalls == 2 && legacy.ownedPortals(sessionKey: "A").isEmpty,
          "portal scoping: refreshOwned is a no-op unless both session methods are advertised")
    _ = await scoped.close("board", scope: scope("A"))
    _ = await scoped.close("clock", scope: scope("A", [tool]))
    let sessionCloses = await calls.count("portal.session.close"), globalCloses = await calls.count("portal.close")
    check(sessionCloses == 1 && globalCloses == 1,
          "portal scoping: owned portals close via portal.session.close, attributed ones via portal.close")
    scoped.handleReconnect()
    check(scoped.ownedPortals(sessionKey: "A").isEmpty, "portal scoping: a reconnect clears the owned cache")
}

private actor Counter {
    private var counts: [String: Int] = [:]
    func bump(_ key: String) { counts[key, default: 0] += 1 }
    func count(_ key: String) -> Int { counts[key, default: 0] }
}

@MainActor
func runDemoPortalChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("portal Demo connection", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "portal demo connects")
        return
    }
    let store = gateway.portals
    let ok1 = await waitFor("demo portals", timeout: 10, { store.portals.count == 2 })
    check(ok1, "demo: the Studio clock and Build dashboard portals are listed")
    let portal = store.portals.first { $0.title == "Studio clock" }
    check(portal?.title == "Studio clock" && portal?.loadURL != nil && portal?.isRedacted == false && !store.unavailable,
          "demo: the portal has a title and an access link")
    check(portal?.displayURL.absoluteString.contains("openclaw_portal") == false, "demo: the display URL has no token")
    check(portal.map { PortalOriginPolicy.allows($0.loadURL!, portal: $0) } == true, "demo: its load URL stays inside its origin")

    // #1029: the portal belongs to the coder agent (Forge); other agents' chats show none.
    let coderChat = gateway.chat(for: DemoGateway.studioClockSessionKey)
    await coderChat.load()
    let otherChat = gateway.chat(for: "agent:main:main")
    await otherChat.load()
    store.trackOwned(sessionKey: coderChat.sessionKey, agentId: coderChat.agentId)
    func shown(_ chat: ChatStore) -> [String] {
        store.portals(for: PortalScope(sessionKey: chat.sessionKey, agentId: chat.agentId, opened: chat.openedPortals)).map(\.title)
    }
    check(coderChat.openedPortals.ids.contains(DemoGateway.demoPortalId), "demo: the coder chat's transcript holds the portal open call")
    let ok6 = await waitFor("demo owned portal", timeout: 10, { shown(coderChat).count == 2 })
    check(ok6 && Set(shown(coderChat)) == ["Studio clock", "Build dashboard"], "demo: the coder agent's chat shows Studio clock and its owned Build dashboard (\(shown(coderChat)))")
    let usesDispatch = TranscriptBuilder.build(coderChat.items).contains { entry in
        if case let .assistant(turn) = entry { return turn.tools.contains { $0.name == "dispatch_action" && $0.openedPortal?.id == DemoGateway.demoPortalId } }
        return false
    }
    check(usesDispatch, "demo: the Studio clock is opened through dispatch_action, as upstream Tool Search records it")
    // chatPortals(for:) is exactly this scoped list: non-empty shows the Portals toolbar button and the ⋯ menu's Show Portals item.
    check(!shown(coderChat).isEmpty && shown(otherChat).isEmpty,
          "demo: Portals toolbar button and ⋯ Show Portals item are visible in the coder's chat and hidden in another agent's")
    check(shown(otherChat).isEmpty, "demo: another agent's chat shows no portals (\(shown(otherChat)))")
    let research = gateway.chat(for: "agent:research:main")
    check(shown(research).isEmpty, "demo: the research agent's chat shows no portals")

    // Closed behind the store's back: only the redacted portal.changed event can empty the list.
    let reply = try? await gateway.connection.request("portal.close", ["id": .string(portal?.id ?? "")])
    check(reply?["closed"]?.bool == true, "demo: portal.close closes it")
    let ok2 = await waitFor("demo portal.changed", timeout: 10, { store.portals.map(\.title) == ["Build dashboard"] })
    check(ok2, "demo: portal.changed refreshes the list")
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

private func portalFetch(_ url: URL, cookie: String? = nil) async -> (status: Int, setCookie: String?, location: String?)? {
    var request = URLRequest(url: url)
    request.httpShouldHandleCookies = false
    request.timeoutInterval = 10
    if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    guard let (_, response) = try? await URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil).data(for: request),
          let http = response as? HTTPURLResponse else { return nil }
    return (http.statusCode, http.value(forHTTPHeaderField: "Set-Cookie"), http.value(forHTTPHeaderField: "Location"))
}

@MainActor
func runLivePortalChecks(url: String, token: String) async {
    func connect(_ name: String) async -> GatewayStore? {
        let profile = GatewayProfile(name: name, url: url, authMode: .token, access: .admin)
        profile.secret = token
        let gateway = GatewayStore(profile: profile)
        gateway.start()
        gateway.reconnectIfNeeded()
        guard await waitFor("\(name) connected", timeout: 25, { gateway.state.isConnected && !gateway.sessions.isEmpty }) else { return nil }
        return gateway
    }
    guard let gateway = await connect("Mock portals"), let watcher = await connect("Mock portal watcher") else {
        check(false, "portals: mock connected")
        return
    }
    defer { gateway.stop(); watcher.stop() }

    let ok3 = await waitFor("mock portals", timeout: 10, { gateway.portals.portals.count == 2 })
    check(ok3, "mock: both portals are listed")
    guard let portal = gateway.portals.portals.first, let load = portal.loadURL else {
        check(false, "mock: the portal has an access link")
        return
    }
    check(portal.title == "Studio clock" && portal.exposure?.isLoopbackOnly == false && !gateway.portals.redacted,
          "mock: Studio clock with a non-loopback exposure and an access link")
    check(PortalOriginPolicy.allows(load, portal: portal) && !portal.displayURL.absoluteString.contains("openclaw_portal"),
          "mock: the access link stays on the portal's origin; the display URL has no token")
    let ok4 = await waitFor("watcher portals", timeout: 10, { watcher.portals.portals.count == 2 })
    check(ok4, "mock: a second connection sees the portals")

    let first = await portalFetch(load)
    check(first?.status == 200 && first?.setCookie?.contains("HttpOnly") == true && first?.setCookie?.contains("SameSite=Lax") == true,
          "mock: GET with the token → 200 and an HttpOnly cookie (\(first?.status ?? -1))")
    let bare = await portalFetch(portal.publicURL)
    check(bare?.status == 401, "mock: GET without a token → 401 (\(bare?.status ?? -1))")
    if let cookie = first?.setCookie?.split(separator: ";").first.map(String.init) {
        let again = await portalFetch(portal.publicURL, cookie: cookie)
        check(again?.status == 200 && again?.setCookie == nil, "mock: the cookie alone then loads it (\(again?.status ?? -1))")
    } else {
        check(false, "mock: the cookie alone then loads it")
    }

    let other = gateway.portals.portals.first(where: { $0.id != portal.id })
    if let other, let cookie = first?.setCookie?.split(separator: ";").first.map(String.init) {
        let crossed = await portalFetch(other.publicURL, cookie: cookie)
        check(crossed?.status == 401, "mock: one portal's cookie gets a 401 on another portal (\(crossed?.status ?? -1))")
        if let otherLoad = other.loadURL {
            let own = await portalFetch(otherLoad)
            check(own?.status == 200, "mock: the other portal opens with its own token (\(own?.status ?? -1))")
            var parts = URLComponents(url: otherLoad, resolvingAgainstBaseURL: false)
            parts?.path = "/redirect-out"
            let hopURL = parts?.url
            let hop = hopURL == nil ? nil : await portalFetch(hopURL!)
            check(hop?.status == 302 && hop?.location?.hasPrefix("http://example.com") == true,
                  "mock: /redirect-out with the token 302s to example.com (\(hop?.status ?? -1))")
            // The web view cancels it: off-origin, and a server redirect carries no user gesture, so it never opens externally.
            let target = hop?.location.flatMap(URL.init(string:))
            check(target.map { !PortalOriginPolicy.allows($0, portal: other) } == true, "mock: the portal's origin lock denies the redirect target")
            parts?.queryItems = nil
            let bareURL = parts?.url
            let bareHop = bareURL == nil ? nil : await portalFetch(bareURL!)
            check(bareHop?.status == 401, "mock: /redirect-out without a token → 401 (\(bareHop?.status ?? -1))")
        }
    } else {
        check(false, "mock: a second portal (Build dashboard) is listed")
    }

    // Closed on the first connection; the watcher only learns of it from the redacted portal.changed event.
    let closed = await gateway.portals.close(portal.id)
    check(closed && gateway.portals.portals.map(\.id) == [other?.id].compactMap(\.self), "mock: portal.close removes only that portal")
    let ok5 = await waitFor("watcher portal.changed", timeout: 10, { watcher.portals.portals.count == 1 && watcher.portals.portals.first?.id != portal.id })
    check(ok5, "mock: portal.changed refreshes another connection")
    let gone = await portalFetch(load)
    check(gone == nil || gone?.status != 200, "mock: a closed portal's server stops answering")
}

/// #1029 against the mock: "Studio clock" is attributed to the coder's main chat (its `portal` tool call), "Build
/// dashboard" is owned by another session through the session methods. No other session sees either one.
@MainActor
func runLivePortalScopingChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock portal scoping", url: url, authMode: .token, access: .admin)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    defer { gateway.stop() }
    guard await waitFor("scoping connected", timeout: 25, { gateway.state.isConnected && !gateway.sessions.isEmpty }),
          await waitFor("scoping portals", timeout: 10, { gateway.portals.portals.count == 2 }) else {
        check(false, "portal scoping live: connected with both portals listed")
        return
    }
    let clockKey = "agent:coder:main", ownedKey = "agent:coder:dashboard:retry-fix", otherKey = "agent:main:main"
    let sessionMethods = gateway.hello?.methods.contains("portal.session.list") == true
    let clockChat = gateway.chat(for: clockKey)
    await clockChat.load()
    check(clockChat.openedPortals.ids.contains("portal_studio_clock"), "portal scoping live: the coder's chat history holds the portal open call")
    let ownedChat = gateway.chat(for: ownedKey)
    await ownedChat.load()
    let otherChat = gateway.chat(for: otherKey)
    await otherChat.load()
    for chat in [clockChat, ownedChat, otherChat] { await gateway.portals.refreshOwned(sessionKey: chat.sessionKey, agentId: chat.agentId) }
    func shown(_ chat: ChatStore) -> [String] {
        gateway.portals.portals(for: PortalScope(sessionKey: chat.sessionKey, agentId: chat.agentId, opened: chat.openedPortals)).map(\.title)
    }
    check(!shown(clockChat).isEmpty && shown(otherChat).isEmpty,
          "portal scoping live: Portals toolbar button and ⋯ Show Portals item are visible in the coder's chat (dispatch_action history) and hidden in another agent's")
    // Per agent: the attributed portal shows in every chat of the coder agent, even one that never ran `portal`.
    check(shown(ownedChat).contains("Studio clock"), "portal scoping live: another chat of the same agent shows Studio clock (\(shown(ownedChat)))")
    check(shown(otherChat).isEmpty, "portal scoping live: another agent's chat shows no portals (\(shown(otherChat)))")
    if sessionMethods {
        check(shown(clockChat) == ["Studio clock", "Build dashboard"], "portal scoping live: the agent's main chat shows attributed and sibling-owned portals (\(shown(clockChat)))")
        check(shown(ownedChat) == ["Studio clock", "Build dashboard"], "portal scoping live: the owning session shows both (\(shown(ownedChat)))")
    } else {
        check(shown(clockChat) == ["Studio clock"] && shown(ownedChat) == ["Studio clock"],
              "portal scoping live: without the session methods only the attributed portal shows (\(shown(clockChat)))")
    }
}
