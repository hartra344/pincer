import Foundation

/// The demo's `browser.request` (`GET /tabs`, `POST /screencast`).
/// Real Gateways need `operator.admin`; the demo counts as Full Management. The screencast
/// `wsPath` uses `demo-screencast://<targetId>`, which Pincer maps to `BrowserDemoFrameSource`.
extension DemoGateway {

    func handleBrowser(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        guard method == "browser.request" else { return nil }
        guard let verb = params["method"]?.string, let path = params["path"]?.string else {
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "invalid browser.request params", details: nil)
        }
        switch (verb, path) {
        case ("GET", "/tabs"):
            let tabs = BrowserDemoPages.all.map { page -> JSONValue in
                ["targetId": .string(page.targetId), "title": .string(page.title), "url": .string(page.url)]
            }
            return ["running": true, "tabs": .array(tabs), "canAutoResizeViewport": true]
        case ("POST", "/screencast"):
            let targetId = params["body"]?["targetId"]?.text ?? BrowserDemoPages.docs.targetId
            guard let page = BrowserDemoPages.page(targetId: targetId) else {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "tab not found", details: nil)
            }
            return ["token": "demo", "wsPath": .string("\(BrowserDemoFrameSource.scheme)://\(page.targetId)"),
                    "targetId": .string(page.targetId), "url": .string(page.url)]
        default:
            throw GatewayError.rpc(code: "INVALID_REQUEST", message: "The demo doesn't support browser \(verb) \(path).",
                                   details: nil)
        }
    }
}
