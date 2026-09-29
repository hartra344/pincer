import Foundation
import PincerKit

// pincer://open links and Handoff activities: one router (`PincerRoute`) parses, builds and
// resolves them. Links only ever navigate; they never send, approve or answer anything.

@MainActor
func runDeepLinkChecks() {
    let gatewayId = UUID(uuidString: "0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9")!
    func parse(_ text: String) -> PincerRoute? { URL(string: text).flatMap(PincerRoute.parse) }
    func route(_ key: String?, _ message: String? = nil) -> PincerRoute {
        PincerRoute(gateway: .id(gatewayId), sessionKey: key, messageId: message)
    }

    check(parse("pincer://open?gateway=\(gatewayId.uuidString)&session=agent:main:main") == route("agent:main:main"),
          "pincer://open parses gateway and session")
    check(parse("pincer://open?gateway=\(gatewayId.uuidString.lowercased())&session=agent%3Amain%3Amain&message=m-1")
        == route("agent:main:main", "m-1"), "lowercase UUID, encoded session and message id parse")
    check(parse("pincer://open?gateway=\(gatewayId.uuidString)") == route(nil), "a link without a session opens the gateway")
    check(parse("pincer://open?gateway=demo&session=agent:main:main")?.gateway == .demo, "gateway=demo names the built-in demo")
    check(parse("pincer://open?x=1&gateway=\(gatewayId.uuidString)&session=agent:main:main&send=hi&approve=allow-always")
        == route("agent:main:main"), "unknown parameters (send, approve…) are ignored")

    let malformed = [
        "https://open?gateway=\(gatewayId.uuidString)&session=agent:main:main",
        "pincer://send?gateway=\(gatewayId.uuidString)&session=agent:main:main",
        "pincer://approve?gateway=\(gatewayId.uuidString)&session=agent:main:main",
        "pincer://open?session=agent:main:main",
        "pincer://open?gateway=nope&session=agent:main:main",
        "pincer://open",
    ]
    let accepted = malformed.filter { parse($0) != nil }
    check(accepted.isEmpty, "malformed links are rejected (accepted: \(accepted))")

    let keys = ["agent:main:discord:channel:123", "agent:main:slack:C01/thread:1700000000.1234", "agent:x:a&b=c+d#e f?g%25"]
    for key in keys {
        let route = route(key, "msg/1")
        let url = route.url
        let query = url.query(percentEncoded: true) ?? ""
        check(url.scheme == "pincer" && url.host() == "open" && !query.contains(":") && !query.contains("/")
              && PincerRoute.parse(url) == route && parse(url.absoluteString) == route,
              "\(key) round-trips through \(url.absoluteString)")
    }

    let handoff = route("agent:main:slack:C01/thread:1", "m-2")
    let plist = (try? PropertyListSerialization.data(fromPropertyList: handoff.userInfo, format: .binary, options: 0))
        .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [AnyHashable: Any] }
    check(PincerRoute(userInfo: plist) == handoff, "Handoff userInfo is plist-safe and round-trips")
    check(PincerRoute(userInfo: [:]) == nil && PincerRoute(userInfo: ["gateway": "nope", "session": "k"]) == nil,
          "malformed Handoff userInfo is rejected")
    check(IntentID.parse(IntentID.scoped(gatewayId, "agent:main:main"))
        .map { PincerRoute(gateway: .id($0.gatewayId), sessionKey: $0.local) } == route("agent:main:main"),
          "route ids match App Intents ids")
    check(route("agent:main:main").resolve(in: [PincerRoute.Candidate]()) == .unknownGateway, "no gateways → unknown gateway")
}

/// Links against the built-in demo: they add and open demo chats, report unknown ones, and never act.
@MainActor
func runDemoDeepLinks() async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    guard app.gateways.isEmpty else { return check(false, "deep-link checks need an empty profile list") }
    let homeLab = "agent:main:discord:channel:123"
    let main = "agent:main:main"
    let ghostKey = "agent:main:dashboard:nope"

    // A demo link on a device without the demo adds it and opens the chat.
    guard let first = URL(string: "pincer://open?gateway=demo&session=\(homeLab)").flatMap(PincerRoute.parse)
    else { return check(false, "demo link parses") }
    let added = app.open(first)
    guard let demo = app.gateways.first(where: \.profile.isDemo) else { return check(false, "a demo link adds the demo (\(added))") }
    check(app.selectedGatewayId == demo.id && demo.selectedKey == homeLab,
          "a demo link adds the demo and opens home-lab (\(added), selected \(demo.selectedKey ?? "none"))")
    let ready = await waitFor("demo connection") { demo.state.isConnected && !demo.sessions.isEmpty && !demo.approvals.isEmpty }
    check(ready, "deep-link demo connected")
    guard ready else { return }

    // Opening home-lab marks it read (a sessions.patch that bumps its activity). Settle that first, so a
    // late mark-read isn't mistaken for activity caused by the links below.
    let lab = demo.chat(for: homeLab)
    _ = await waitFor("home-lab history") { lab.hasLoaded }
    await demo.markRead(homeLab)
    let read = await waitFor("home-lab read") { demo.sessions[homeLab]?.isUnread == false }
    check(read, "opening home-lab marks it read")
    demo.selectedKey = main
    app.updateVisible()
    let approvalsBefore = demo.approvals.map(\.id)
    let activityBefore = demo.sessions.mapValues(\.activityMs)
    // The demo seeds runs already in flight (a running subagent, and the Sessions page's run duration); only new runs count.
    let runningBefore = Set(demo.sessions.values.filter(\.hasActiveRun).map(\.key))

    // A link that also carries would-be actions: only the navigation part may happen.
    let link = app.route(for: Notifier.Target(gatewayId: demo.id, sessionKey: homeLab), messageId: "demo-lab-sensor")
    check(link.gateway == .demo && link.url.absoluteString.hasPrefix("pincer://open?gateway=demo&"),
          "links to demo chats name the demo, not its per-device id (\(link.url.absoluteString))")
    let text = link.url.absoluteString + "&send=rm%20-rf&approve=allow-always&decision=allow-once"
    guard let route = URL(string: text).flatMap(PincerRoute.parse) else { return check(false, "demo link parses: \(text)") }
    let target = Notifier.Target(gatewayId: demo.id, sessionKey: homeLab)
    let resolution = app.open(route)
    check(resolution == .openChat(target, messageId: "demo-lab-sensor"), "demo link resolves to home-lab at the sensor message")
    check(app.selectedGatewayId == demo.id && demo.selectedKey == homeLab && app.history.current == target,
          "opening the demo link selects home-lab and records history")
    let jump = app.takeMessageJump(for: target)
    check(jump?.messageId == "demo-lab-sensor" && app.takeMessageJump(for: target) == nil, "the message jump is taken once")
    let loaded = await waitFor("home-lab history") { lab.hasLoaded }
    check(loaded && lab.entries.contains { $0.id.hasSuffix("demo-lab-sensor") },
          "the linked message is in home-lab's transcript")

    let byId = PincerRoute(gateway: .id(demo.id), sessionKey: main)
    check(app.open(byId) == .openChat(Notifier.Target(gatewayId: demo.id, sessionKey: main), messageId: nil)
          && demo.selectedKey == main && app.takeMessageJump(for: Notifier.Target(gatewayId: demo.id, sessionKey: main)) == nil,
          "a link by the demo's id opens its chat, with no stale jump")
    check(app.open(PincerRoute(gateway: .demo, sessionKey: "agent:research:main")) != nil
          && demo.selectedKey == "agent:research:main", "a demo link to another agent opens Scout's main chat")

    app.routeNotice = nil
    let ghost = app.open(PincerRoute(gateway: .demo, sessionKey: ghostKey))
    check(ghost == .unknownSession(gatewayId: demo.id, sessionKey: ghostKey)
          && app.routeNotice != nil && app.selectedGatewayId == demo.id,
          "unknown demo chat → unknown session with a notice (\(app.routeNotice?.message ?? "none"))")
    app.routeNotice = nil
    let selectedBefore = (app.selectedGatewayId, demo.selectedKey)
    check(app.open(PincerRoute(gateway: .id(UUID()), sessionKey: main)) == .unknownGateway && app.routeNotice != nil
          && app.selectedGatewayId == selectedBefore.0 && demo.selectedKey == selectedBefore.1,
          "unknown gateway id → notice, selection unchanged")
    app.routeNotice = nil
    check(app.open(url: URL(string: "pincer://approve?gateway=demo&session=\(main)")!) == nil && app.routeNotice != nil,
          "an unsupported pincer:// link does nothing but leave a notice")
    app.routeNotice = nil
    check(app.open(url: URL(string: "https://example.com/open?gateway=demo")!) == nil && app.routeNotice == nil,
          "non-pincer URLs are ignored silently")

    let fromHandoff = PincerRoute(userInfo: route.userInfo)
    check(fromHandoff.map { app.open($0) } == .openChat(target, messageId: "demo-lab-sensor"),
          "Handoff userInfo opens the same chat as the link")

    // Every entry point shares the router: a notification tap for a chat not listed yet still opens it.
    let fresh = Notifier.Target(gatewayId: demo.id, sessionKey: "agent:main:dashboard:just-made")
    app.notifier.onOpen?(fresh)
    check(demo.selectedKey == fresh.sessionKey && app.history.current == fresh, "a notification tap opens its chat through the router")
    let paletteTarget = Notifier.Target(gatewayId: demo.id, sessionKey: main)
    app.open(app.route(for: paletteTarget), find: "disk", match: nil)
    check(demo.selectedKey == main && app.takeFindRequest(for: paletteTarget)?.query == "disk",
          "a search result opens through the router with its find request")

    // Links carry nothing but where to go.
    let profilesBefore = app.gateways.map { "\($0.id) \($0.profile.name) \($0.profile.url)" }
    let listRequests = app.gatewayListRequests
    app.routeNotice = nil
    let unknownId = UUID()
    let unknown = URL(string: "pincer://open?gateway=\(unknownId.uuidString)&session=\(ghostKey)&token=abc&url=ws://127.0.0.1:1")!
    check(app.open(url: unknown) == .unknownGateway && app.gatewayListRequests == listRequests + 1
          && app.routeNotice?.message == PincerRoute.Notice.unknownGateway,
          "unknown gateway shows the gateway list and its notice")
    check(app.routeNotice.map { !$0.message.contains(unknownId.uuidString) && !$0.message.contains(ghostKey) } == true,
          "notices never echo raw ids")
    app.open(url: URL(string: "pincer://open?gateway=demo&session=\(homeLab)&text=rm%20-rf%20%2F&message=demo-lab-sensor&approve=1")!)
    check(demo.selectedKey == homeLab && lab.draft.isEmpty, "a link with text= leaves the composer empty")
    check(app.gateways.map { "\($0.id) \($0.profile.name) \($0.profile.url)" } == profilesBefore,
          "links neither add nor edit gateways (\(app.gateways.count) saved)")

    // Give any stray send/resolve a moment to surface.
    try? await Task.sleep(for: .milliseconds(800))
    let running = demo.sessions.values.filter { $0.hasActiveRun && !runningBefore.contains($0.key) }.map(\.key)
    check(running.isEmpty, "no run started by opening links (\(running))")
    check(demo.approvals.map(\.id) == approvalsBefore, "no approval resolved by opening links")
    check(demo.sessions[homeLab]?.activityMs == activityBefore[homeLab], "home-lab saw no new activity")

    // A saved gateway that isn't connected (here: nothing listening, so it keeps retrying): the
    // link selects it and its chat, which opens once listed; nothing is sent meanwhile.
    let offline = app.add(GatewayProfile(name: "Offline", url: "ws://127.0.0.1:9", authMode: .token), secret: "t")
    let retrying = await waitFor("offline retry", timeout: 10) {
        if case .reconnecting = offline.state { return true }
        return false
    }
    check(retrying, "the offline gateway is retrying (\(offline.state))")
    app.open(Notifier.Target(gatewayId: demo.id, sessionKey: main))
    let offlineKey = "agent:main:main"
    check(app.open(PincerRoute(gateway: .id(offline.id), sessionKey: offlineKey)) == .openChat(
        Notifier.Target(gatewayId: offline.id, sessionKey: offlineKey), messageId: nil)
          && app.selectedGatewayId == offline.id && offline.selectedKey == offlineKey,
          "a link to a disconnected gateway selects it and its chat")
    check(offline.state != .idle && !offline.state.isConnected && offline.sessions.isEmpty,
          "the disconnected gateway keeps connecting; nothing is listed or sent (\(offline.state))")
}

/// Against a (mock) Gateway: links built from live session keys and message ids resolve and open.
@MainActor
func runLiveDeepLinks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let gateway = app.add(GatewayProfile(name: "Mock", url: url, authMode: .token), secret: token)
    let ready = await waitFor("live connection", timeout: 25) { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(ready, "deep-link live connected")
    guard ready else { return }
    let keys = gateway.sessions.keys.sorted()
    let unresolved = keys.filter { key in
        let route = app.route(for: Notifier.Target(gatewayId: gateway.id, sessionKey: key))
        return PincerRoute.parse(route.url) != route
            || route.resolve(in: app.gateways) != .openChat(Notifier.Target(gatewayId: gateway.id, sessionKey: key), messageId: nil)
    }
    check(unresolved.isEmpty, "every live session key round-trips and resolves (\(keys.count) keys; failed: \(unresolved))")

    // Handoff from another device (#375): its id for this gateway differs, and it reaches the
    // gateway by another address, but the host name the gateway reports is the same.
    let host = await waitFor("reported gateway host", timeout: 5) { gateway.gatewayHost != nil }
    check(host && gateway.gatewayHost == "pincer-mock-gateway.local", "the gateway's own host is saved (\(gateway.gatewayHost ?? "none"))")
    check(app.route(for: Notifier.Target(gatewayId: gateway.id, sessionKey: "agent:main:main")).handoffUserInfo[PincerRoute.Key.host]
          == gateway.gatewayHost, "Handoff carries the gateway's host")
    let fromPhone = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:main",
                                gatewayURL: "wss://pincer-mock-gateway.tail1234.ts.net", gatewayHost: "Pincer-Mock-Gateway.local.")
    check(app.open(fromPhone) == .openChat(Notifier.Target(gatewayId: gateway.id, sessionKey: "agent:main:main"), messageId: nil),
          "Handoff from another device, other id and address, opens the chat here")

    let key = "agent:main:discord:channel:123"
    gateway.selectedKey = "agent:main:main"
    app.updateVisible()
    let lab = gateway.chat(for: key)
    await lab.load()
    // The Gateway's message id (`__openclaw.id`), as a link from outside would carry it.
    let messageId = lab.entries.last.map { String($0.id.drop { $0 != "-" }.dropFirst()) }
    let approvalsBefore = gateway.approvals.map(\.id)
    let route = app.route(for: Notifier.Target(gatewayId: gateway.id, sessionKey: key), messageId: messageId)
    check(route.gateway == .id(gateway.id), "live links carry the gateway's id")
    check(!route.url.absoluteString.contains(token) && !route.handoffUserInfo.values.contains { $0.contains(token) },
          "live links and Handoff never carry the token")
    check(app.open(url: route.url) == .openChat(Notifier.Target(gatewayId: gateway.id, sessionKey: key), messageId: messageId)
          && app.selectedGatewayId == gateway.id && gateway.selectedKey == key,
          "opening a live link selects the chat (message \(messageId ?? "none"))")
    // Negative window: opening a link must not send or approve anything.
    try? await Task.sleep(for: .milliseconds(500))
    check(gateway.sessions[key]?.hasActiveRun == false && gateway.approvals.map(\.id) == approvalsBefore,
          "opening a live link sends and approves nothing")
}
