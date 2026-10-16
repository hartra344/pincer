import Foundation
@testable import PincerKit

@MainActor
func runBrowserControlsOfflineChecks() {
    func norm(_ s: String) -> String? { BrowserURLDraft.normalize(s)?.absoluteString }
    check(norm("docs.openclaw.ai") == "https://docs.openclaw.ai", "controls: a domain gets https")
    check(norm("localhost:3000") == "http://localhost:3000", "controls: localhost:3000 is host:port, not a scheme")
    check(norm("127.0.0.1:8080") == "http://127.0.0.1:8080" && norm("192.168.1.10") == "http://192.168.1.10", "controls: IPs get http")
    check(norm("[::1]:3000") == "http://[::1]:3000", "controls: IPv6 literals get http")
    check(norm("about:blank") == "about:blank", "controls: about:blank is allowed")
    check(norm("  example.com \n") == "https://example.com", "controls: input is trimmed")
    let rejected = ["", "foo", "my search terms", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "chrome://settings",
                    "ftp://example.com", "user:pass@example.com", "https://user:pass@example.com/"]
    check(rejected.allSatisfy { norm($0) == nil }, "controls: other schemes, bare words, spaces and userinfo are rejected")
    check(norm(String(repeating: "a", count: 3000) + ".com") == nil, "controls: an oversized address is rejected")

    let blocked = GatewayError.rpc(code: "INVALID_REQUEST", message: "x", details: ["reason": "navigation_blocked"])
    let disabled = GatewayError.rpc(code: "INVALID_REQUEST", message: "x", details: ["code": "ACT_EVALUATE_DISABLED"])
    let legacy = GatewayError.rpc(code: "INVALID_REQUEST", message: "browser.evaluateEnabled=false", details: nil)
    check(BrowserPanelModel.isNavigationBlocked(blocked) && !BrowserPanelModel.isNavigationBlocked(disabled), "controls: navigation_blocked is recognised")
    check(BrowserPanelModel.isEvaluateDisabled(disabled) && BrowserPanelModel.isEvaluateDisabled(legacy) && !BrowserPanelModel.isEvaluateDisabled(blocked),
          "controls: evaluate-disabled is recognised by code, or by message when no code is given")
    check(BrowserPanelModel.safeFilename("../../a:b.html") == "a_b.html" && BrowserPanelModel.safeFilename(nil) == "page.html"
          && BrowserPanelModel.safeFilename(String(repeating: "x", count: 400)).count == 200,
          "controls: download file names are sanitised")
}

@MainActor
func runDemoBrowserControlsChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil
    gateway.outboxRoot = nil
    gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("controls Demo connection", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "browser controls demo connects")
        return
    }
    let model = gateway.browserPanel
    await model.refreshTabs()
    let first = BrowserDemoPages.docs.targetId
    model.select(targetId: first)
    let originalTitle = model.selectedTab?.title

    await model.navigate(to: "example.com")
    check(model.selectedTab?.url?.host == "example.com" && model.selectedTab?.title != originalTitle,
          "demo controls: navigate changes the page and its title (\(model.selectedTab?.title ?? "nil"))")
    check(model.actionError == nil && !model.isNavigating, "demo controls: a navigate leaves no error and no spinner")
    await model.goBack()
    check(model.selectedTab?.title == originalTitle, "demo controls: Back returns to the first page")
    await model.goForward()
    check(model.selectedTab?.url?.host == "example.com", "demo controls: Forward returns to the second page")
    check(!model.historyUnavailable, "demo controls: history stays available")
    await model.navigate(to: "blocked.example/x")
    check(model.actionError == "This address is blocked by the gateway's browser policy.", "demo controls: a blocked address shows the fixed message")
    await model.navigate(to: "javascript:alert(1)")
    check(model.actionError == "Enter a web address", "demo controls: a non-web address is refused locally")

    let before = model.tabs.count
    await model.openTab(url: "swift.org")
    check(model.tabs.count == before + 1 && model.selectedTab?.url?.host == "swift.org", "demo controls: New Tab opens and selects the page")
    let opened = model.selectedTargetId ?? ""
    await model.closeTab(opened)
    check(model.tabs.count == before && !model.tabs.contains { $0.targetId == opened } && model.selectedTargetId != nil,
          "demo controls: Close Tab removes it and selects a neighbour")

    model.select(targetId: first)
    do {
        let file = try await model.downloadCurrentPage()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(file.pathExtension == "html" && text.contains("<h1>") && !model.isDownloading, "demo controls: Download Page yields an HTML file with bytes (\(file.lastPathComponent))")
    } catch {
        check(false, "demo controls: Download Page (\(error))")
    }

    model.setVisible(true, pixelSize: CGSize(width: 800, height: 600))
    await model.navigate(to: "docs.openclaw.ai")
    let live = await waitFor("demo frame after navigate", timeout: 20) { model.status == .live && model.frame != nil }
    check(live, "demo controls: frames keep arriving after navigating (\(model.status))")
    model.stop()
}

@MainActor
func runLiveBrowserControlsChecks(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock browser controls", url: url, authMode: .token, access: .admin)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    gateway.reconnectIfNeeded()
    guard await waitFor("mock for browser controls", timeout: 25, { gateway.state.isConnected && gateway.bootstrapped }) else {
        check(false, "browser controls: mock connected")
        return
    }
    defer { gateway.stop() }
    let model = gateway.browserPanel
    let probe = try? await gateway.connection.request("browser.request", ["method": "GET", "path": "/tabs"])
    if probe?["running"]?.bool == false {
        // MOCK_BROWSER_STOPPED=1: /tabs reports running:false until /start.
        model.setVisible(true, pixelSize: CGSize(width: 800, height: 600))
        let stopped = await waitFor("stopped browser", timeout: 10, { model.status == .notRunning })
        check(stopped, "mock controls: a stopped browser shows the not-running state")
        await model.startBrowser()
        let up = await waitFor("browser started", timeout: 20) { !model.tabs.isEmpty && model.status != .notRunning }
        check(up && model.actionError == nil, "mock controls: Start Browser brings the browser up (\(model.status))")
        model.stop()
        return
    }
    await model.refreshTabs()
    guard let docs = model.tabs.first(where: { $0.targetId == "tab-docs-0001" }) else {
        check(false, "mock controls: the seeded docs tab is listed")
        return
    }
    model.select(targetId: docs.targetId)

    await model.navigate(to: "example.com/controls")
    check(model.selectedTab?.url?.host == "example.com" && model.actionError == nil,
          "mock controls: navigate moves the selected tab (\(model.selectedTab?.url?.absoluteString ?? "nil"))")
    await model.goBack()
    if model.historyUnavailable {
        // MOCK_BROWSER_EVALUATE_DISABLED=1: Back and Forward turn off after the first refusal.
        check(model.actionError == nil, "mock controls: an evaluate-disabled refusal sets the flag, not an error line")
        await model.navigate(to: "example.com/after")
        check(model.selectedTab?.url?.path == "/after" && model.historyUnavailable, "mock controls: navigate still works with history turned off")
        model.handleReconnect()
        check(!model.historyUnavailable, "mock controls: a reconnect re-enables Back and Forward")
        return
    }
    check(model.selectedTab?.url?.host == docs.url?.host && !model.historyUnavailable, "mock controls: Back returns to the first page")
    await model.goForward()
    check(model.selectedTab?.url?.host == "example.com", "mock controls: Forward returns to the second page")

    await model.navigate(to: "blocked.example")
    check(model.actionError == "This address is blocked by the gateway's browser policy.", "mock controls: a blocked address maps to its reason")

    let before = model.tabs.count
    await model.openTab(url: "swift.org")
    check(model.tabs.count == before + 1 && model.selectedTab?.url?.host == "swift.org", "mock controls: New Tab opens and selects the page")
    let opened = model.selectedTargetId ?? ""
    await model.closeTab(opened)
    check(!model.tabs.contains { $0.targetId == opened } && model.tabs.count == before, "mock controls: Close Tab removes the page")

    await model.startBrowser()
    check(model.actionError == nil && !model.tabs.isEmpty, "mock controls: Start Browser succeeds on a running browser")

    model.select(targetId: docs.targetId)
    do {
        let file = try await model.downloadCurrentPage()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        check(size > 0 && !model.isDownloading, "mock controls: Download Page fetches the bytes over the media route (\(file.lastPathComponent), \(size) bytes)")
    } catch {
        check(false, "mock controls: Download Page (\(error))")
    }

    model.setVisible(true, pixelSize: CGSize(width: 800, height: 600))
    let live = await waitFor("mock frame after controls", timeout: 20) { model.status == .live && model.frame != nil }
    check(live, "mock controls: the screencast still delivers frames after navigating (\(model.status))")
    model.stop()
}
