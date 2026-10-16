import Observation
import PincerKit
import SwiftUI
import WebKit

#if os(macOS)
private typealias PortalViewRepresentable = NSViewRepresentable
#else
private typealias PortalViewRepresentable = UIViewRepresentable
#endif

/// Why a portal page isn't showing. Never holds a URL or token.
enum PortalFailure: Equatable {
    /// 401 or 404: the access link expired or the portal closed.
    case expired
    case message(String)
}

/// A main-frame navigation the origin lock cancelled. `openURL` is the http(s) address without the
/// access token, or nil when opening it outside wouldn't make sense (a form POST).
struct PortalBlockedNavigation: Equatable {
    let host: String
    let openURL: URL?
}

/// What a portal's web view is doing, for the progress bar, URL row and banners.
@MainActor
@Observable
final class PortalWebState {
    var isReady = false
    var isLoading = false
    var progress = 0.0
    var failure: PortalFailure?
    /// The page's current address with the access token removed.
    var currentURL: URL?
    var blocked: PortalBlockedNavigation?
}

/// One portal's web view: its own non-persistent data store, the origin lock and the rest of the
/// hardening. The `WKWebView` is created on main on the run-loop turn after the tab is shown (WebKit
/// requires main; the WebContent process spin-up is the cost), so the tab switch itself never waits on it.
@MainActor
final class PortalWebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let portal: PortalSummary
    let state = PortalWebState()
    private(set) var webView: WKWebView?
    private let pin: (host: String, fingerprint: String)?
    private let servesDemoPortal: Bool
    private var starting = false
    private var observations: [NSKeyValueObservation] = []

    /// `pin` is the gateway's host and certificate fingerprint when the profile pins one; it only
    /// applies to a portal served from that same host.
    init(portal: PortalSummary, pin: (host: String, fingerprint: String)? = nil, servesDemoPortal: Bool = false) {
        self.portal = portal
        self.pin = pin
        self.servesDemoPortal = servesDemoPortal
    }

    /// Creates the web view (next run-loop turn) and loads the access link; later calls do nothing.
    func loadIfNeeded() {
        guard self.webView == nil, !self.starting else { return }
        self.starting = true
        Task { @MainActor in
            self.starting = false
            guard self.webView == nil else { return }
            self.makeWebView()
            self.reload(force: true)
        }
    }

    private func makeWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        // The bundled demo page is only ever served for the demo gateway.
        if self.servesDemoPortal {
            config.setURLSchemeHandler(DemoPortalSchemeHandler(), forURLScheme: PortalSummary.demoScheme)
        }
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        self.observations = [
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                let value = view.estimatedProgress
                Task { @MainActor in self?.state.progress = value }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                let value = view.isLoading
                Task { @MainActor in self?.state.isLoading = value }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                let value = view.url.map(PortalOriginPolicy.strippedForDisplay)
                Task { @MainActor in self?.state.currentURL = value }
            },
        ]
        self.webView = view
        self.state.isReady = true
    }

    func reload(force: Bool = false) {
        guard let url = self.portal.loadURL, let webView = self.webView else { return }
        self.state.failure = nil
        self.state.blocked = nil
        if force || webView.url == nil {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    func pauseMedia() {
        guard let webView = self.webView else { return }
        Task { await webView.pauseAllMediaPlayback() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void)
    {
        guard let url = navigationAction.request.url, !navigationAction.shouldPerformDownload else { return decisionHandler(.cancel) }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? false
        if PortalOriginPolicy.allows(url, portal: self.portal, isMainFrame: isMain) {
            return decisionHandler(.allow)
        }
        if isMain, let outside = PortalOriginPolicy.externalURL(for: url) {
            let isPost = navigationAction.request.httpMethod?.uppercased() == "POST"
            if navigationAction.navigationType == .linkActivated {
                // Only a deliberate click on a web link leaves the portal; it goes to the system
                // browser without the access token.
                PortalOpener.open(outside)
            } else {
                self.state.blocked = PortalBlockedNavigation(host: url.host(percentEncoded: false) ?? "", openURL: isPost ? nil : outside)
            }
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void)
    {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode == 401 || http.statusCode == 404
        {
            self.state.failure = .expired
            return decisionHandler(.cancel)
        }
        let attachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        decisionHandler(navigationResponse.canShowMIMEType && !attachment ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.noteFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.noteFailure(error)
    }

    private func noteFailure(_ error: Error) {
        let ns = error as NSError
        // A navigation we cancelled ourselves isn't a failure.
        // -999 and WebKit's 102 ("frame load interrupted") come from navigations we cancelled ourselves.
        let interrupted = ns.domain == "WebKitErrorDomain" && ns.code == 102
        if ns.code == NSURLErrorCancelled || interrupted || self.state.failure != nil { return }
        self.state.failure = .message(BrowserPanelModel.sanitized(ns.localizedDescription))
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            // Basic, NTLM and the rest: a portal never gets a credential prompt.
            return (.cancelAuthenticationChallenge, nil)
        }
        guard let pin = self.pin, space.host.lowercased() == pin.host, let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return TLSPin.matches(trust, fingerprint: pin.fingerprint) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView?
    {
        guard let url = navigationAction.request.url else { return nil }
        if PortalOriginPolicy.allows(url, portal: self.portal, isMainFrame: true) {
            // A same-origin popup stays here, so the access cookie never has to leave the panel.
            webView.load(navigationAction.request)
        } else if navigationAction.navigationType == .linkActivated, let outside = PortalOriginPolicy.externalURL(for: url) {
            PortalOpener.open(outside)
        }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void)
    {
        decisionHandler(.deny)
    }
}

/// Keeps at most `limit` live web views, least recently shown first out. An evicted portal reloads
/// when it's selected again. Closed portals are pruned so their data store goes with them.
@MainActor
final class PortalWebCache {
    static let limit = 3
    private var sessions: [String: PortalWebSession] = [:]
    private var order: [String] = []

    /// Web views that exist right now (created and not evicted); the panel-slide probe reads it.
    var liveWebViewCount: Int { self.sessions.values.filter { $0.webView != nil }.count }

    func session(for portal: PortalSummary, pin: (host: String, fingerprint: String)?, servesDemoPortal: Bool = false) -> PortalWebSession {
        if let existing = self.sessions[portal.id], existing.portal.loadURL == portal.loadURL {
            self.order.removeAll { $0 == portal.id }
            self.order.append(portal.id)
            return existing
        }
        let session = PortalWebSession(portal: portal, pin: pin, servesDemoPortal: servesDemoPortal)
        self.sessions[portal.id] = session
        self.order.removeAll { $0 == portal.id }
        self.order.append(portal.id)
        while self.order.count > Self.limit {
            self.sessions[self.order.removeFirst()] = nil
        }
        return session
    }

    func prune(keeping ids: Set<String>) {
        for id in self.sessions.keys where !ids.contains(id) { self.sessions[id] = nil }
        self.order.removeAll { !ids.contains($0) }
    }

    /// The app left the foreground: stop audio and video, keep the pages.
    func pauseAllMedia() {
        self.sessions.values.forEach { $0.pauseMedia() }
    }
}

/// Hosts a session's `WKWebView`; nothing to update, the session drives it.
struct PortalWebViewHost: PortalViewRepresentable {
    let webView: WKWebView

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { self.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView { self.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #endif
}

/// Serves the demo gateway's portal from memory (no network): `demo-portal://studio-clock/`.
final class DemoPortalSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let html = """
    <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
    <title>Studio clock</title>
    <style>
    :root{color-scheme:light dark}
    body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px -apple-system,system-ui,sans-serif;background:#0f172a;color:#e2e8f0}
    main{text-align:center}
    #t{font-size:min(18vw,96px);font-weight:200;font-variant-numeric:tabular-nums;letter-spacing:.02em}
    #d{opacity:.6;margin-top:8px}
    </style>
    <main><div id=t>--:--:--</div><div id=d></div></main>
    <script>
    function tick(){var n=new Date();
    document.getElementById('t').textContent=n.toLocaleTimeString([], {hour12:false});
    document.getElementById('d').textContent=n.toLocaleDateString([], {weekday:'long',month:'long',day:'numeric'})}
    tick();setInterval(tick,1000)
    </script>
    """

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let data = Data(Self.html.utf8)
        let response = URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
