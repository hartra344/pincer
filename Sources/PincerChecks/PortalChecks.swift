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
    let ok1 = await waitFor("demo portal", timeout: 10, { store.portals.count == 1 })
    check(ok1, "demo: the Studio clock portal is listed")
    let portal = store.portals.first
    check(portal?.title == "Studio clock" && portal?.loadURL != nil && portal?.isRedacted == false && !store.unavailable,
          "demo: the portal has a title and an access link")
    check(portal?.displayURL.absoluteString.contains("openclaw_portal") == false, "demo: the display URL has no token")
    check(portal.map { PortalOriginPolicy.allows($0.loadURL!, portal: $0) } == true, "demo: its load URL stays inside its origin")

    // Closed behind the store's back: only the redacted portal.changed event can empty the list.
    let reply = try? await gateway.connection.request("portal.close", ["id": .string(portal?.id ?? "")])
    check(reply?["closed"]?.bool == true, "demo: portal.close closes it")
    let ok2 = await waitFor("demo portal.changed", timeout: 10, { store.portals.isEmpty })
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
