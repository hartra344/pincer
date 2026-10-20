import Foundation

/// The demo's `browser.request` (`GET /tabs`, `POST /screencast`).
/// Real Gateways need `operator.admin`; the demo counts as Full Management. The screencast
/// `wsPath` uses `demo-screencast://<targetId>`, which Pincer maps to `BrowserDemoFrameSource`.
extension DemoGateway {

    func handleBrowser(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        guard method == "browser.request" else { return nil }
        guard let verb = params["method"]?.string, let path = params["path"]?.string else {
            throw GatewayError.invalidRequest("invalid browser.request params")
        }
        let body = params["body"]
        switch (verb, path) {
        case ("GET", "/tabs"):
            return ["running": true, "tabs": .array(self.demoBrowserTabs.map(\.json)), "canAutoResizeViewport": true]
        case ("POST", "/start"):
            return ["running": true]
        case ("POST", "/screencast"):
            let targetId = body?["targetId"]?.text ?? BrowserDemoPages.docs.targetId
            guard let tab = self.demoBrowserTabs.first(where: { $0.targetId == targetId }) else {
                throw GatewayError.invalidRequest("tab not found")
            }
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "url", value: tab.url), URLQueryItem(name: "title", value: tab.title)]
            let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
            return ["token": "demo", "wsPath": .string("\(BrowserDemoFrameSource.scheme)://\(tab.targetId)\(query)"),
                    "targetId": .string(tab.targetId), "url": .string(tab.url)]
        case ("POST", "/navigate"):
            guard let url = body?["url"]?.text, let index = self.demoTabIndex(body?["targetId"]?.text) else {
                throw GatewayError.invalidRequest("tab not found")
            }
            if url.contains("blocked.example") {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "navigation blocked",
                                       details: ["reason": "navigation_blocked"])
            }
            self.demoBrowserTabs[index].visit(url)
            return ["targetId": .string(self.demoBrowserTabs[index].targetId), "url": .string(url)]
        case ("POST", "/tabs/open"):
            guard let url = body?["url"]?.text else {
                throw GatewayError.invalidRequest("url required")
            }
            if url.contains("blocked.example") {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "navigation blocked",
                                       details: ["reason": "navigation_blocked"])
            }
            self.demoBrowserTabCounter += 1
            let tab = DemoBrowserTab(targetId: "DEMO-TAB-\(self.demoBrowserTabCounter)", url: url)
            self.demoBrowserTabs.append(tab)
            return tab.json
        case ("POST", "/act"):
            let fn = body?["fn"]?.text
            guard body?["kind"]?.text == "evaluate", let index = self.demoTabIndex(body?["targetId"]?.text),
                  let delta = DemoBrowserTab.historyDelta(fn)
            else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "The demo only supports history back and forward.",
                                       details: nil)
            }
            self.demoBrowserTabs[index].go(delta)
            return ["ok": true, "result": true]
        case ("POST", "/download"):
            guard let index = self.demoTabIndex(body?["targetId"]?.text) else {
                throw GatewayError.invalidRequest("tab not found")
            }
            let tab = self.demoBrowserTabs[index]
            let host = URL(string: tab.url)?.host ?? "page"
            return ["ok": true, "download": ["path": .string("\(DemoBrowserDownload.scheme)://\(tab.targetId)"),
                                             "suggestedFilename": .string("\(host).html")]]
        case ("DELETE", _) where path.hasPrefix("/tabs/"):
            let id = String(path.dropFirst("/tabs/".count)).removingPercentEncoding ?? ""
            guard let index = self.demoTabIndex(id) else {
                throw GatewayError.invalidRequest("tab not found")
            }
            self.demoBrowserTabs.remove(at: index)
            return ["ok": true]
        default:
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "The demo doesn't support browser \(verb) \(path).",
                                   details: nil)
        }
    }
}

extension DemoGateway {
    func demoTabIndex(_ targetId: String?) -> Int? {
        guard let targetId else { return nil }
        return self.demoBrowserTabs.firstIndex { $0.targetId == targetId }
    }
}

/// One demo tab with its history, so Back and Forward behave.
struct DemoBrowserTab: Sendable {
    let targetId: String
    private(set) var history: [String]
    private(set) var index = 0

    init(targetId: String, url: String) {
        self.targetId = targetId
        self.history = [url]
    }

    init(_ page: BrowserDemoPages.Page) { self.init(targetId: page.targetId, url: page.url) }

    var url: String { self.history[self.index] }
    var title: String {
        BrowserDemoPages.all.first { $0.url == self.url }?.title ?? URL(string: self.url)?.host ?? "New tab"
    }
    var json: JSONValue { ["targetId": .string(self.targetId), "title": .string(self.title), "url": .string(self.url)] }

    mutating func visit(_ url: String) {
        guard url != self.url else { return }
        self.history = Array(self.history[...self.index]) + [url]
        self.index = self.history.count - 1
    }

    mutating func go(_ delta: Int) {
        self.index = min(max(self.index + delta, 0), self.history.count - 1)
    }

    /// Only the two scripts Pincer sends are understood.
    static func historyDelta(_ fn: String?) -> Int? {
        switch fn {
        case "() => { history.go(-1); return true; }": -1
        case "() => { history.go(1); return true; }": 1
        default: nil
        }
    }
}

/// The demo's page download: a small HTML file served in-process (no network).
public enum DemoBrowserDownload {
    public static let scheme = "demo-download"

    public static func data(forPath path: String) -> Data? {
        guard path.hasPrefix("\(scheme)://") else { return nil }
        let id = String(path.dropFirst(scheme.count + 3))
        let page = BrowserDemoPages.page(targetId: id)
        let title = page?.title ?? "Demo page"
        let body = (page?.lines ?? ["The demo gateway doesn't browse the real web."]).map { "<li>\($0)</li>" }.joined()
        return Data("<!doctype html><title>\(title)</title><h1>\(page?.heading ?? title)</h1><ul>\(body)</ul>".utf8)
    }
}
