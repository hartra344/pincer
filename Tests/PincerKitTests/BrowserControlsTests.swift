import Foundation
import Synchronization
import Testing
@testable import PincerKit

/// A scripted gateway for the browser controls: records calls, answers by path, and can hold a request open.
final class ControlsGateway: Sendable {
    struct Call: Sendable { let method: String; let path: String; let body: JSONValue? }
    let calls = Mutex<[Call]>([])
    let sources = Mutex<[FakeBrowserSource]>([])
    let navigateIds = Mutex<[String]>([])
    let failures = Mutex<[String: Error]>([:])
    let held = Mutex<[String: CheckedContinuation<Void, Never>]>([:])
    let holdNext = Mutex<Set<String>>([])
    let preReleased = Mutex<Set<String>>([])
    let tabsJSON = Mutex(#"[{"targetId":"T1","title":"One","url":"https://one.test/"},{"targetId":"T2","title":"Two","url":"https://two.test/"}]"#)

    func count(_ method: String, _ path: String) -> Int { calls.withLock { $0.filter { $0.method == method && $0.path == path }.count } }
    func bodies(_ path: String) -> [JSONValue?] { calls.withLock { $0.filter { $0.path == path }.map(\.body) } }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        let path = params["path"]?.string ?? ""
        let verb = params["method"]?.string ?? ""
        calls.withLock { $0.append(Call(method: verb, path: path, body: params["body"])) }
        if holdNext.withLock({ $0.remove(path) != nil }) {
            await withCheckedContinuation { c in
                // A release that landed before the request parked must not be lost.
                if preReleased.withLock({ $0.remove(path) != nil }) { c.resume() } else { held.withLock { $0[path] = c } }
            }
        }
        if let error = failures.withLock({ $0[path] }) { throw error }
        switch path {
        case "/tabs":
            return Fixtures.json(#"{"running":true,"tabs":\#(tabsJSON.withLock { $0 })}"#)
        case "/screencast":
            let target = params["body"]?["targetId"]?.string ?? "T1"
            return Fixtures.json(#"{"token":"tok","wsPath":"/s?token=tok","targetId":"\#(target)","url":"https://one.test/"}"#)
        case "/navigate":
            let id = navigateIds.withLock { $0.isEmpty ? nil : $0.removeFirst() } ?? params["body"]?["targetId"]?.string ?? "T1"
            return Fixtures.json(#"{"ok":true,"targetId":"\#(id)","url":"\#(params["body"]?["url"]?.string ?? "")"}"#)
        case "/tabs/open":
            return Fixtures.json(#"{"targetId":"T3","title":"New","url":"\#(params["body"]?["url"]?.string ?? "")"}"#)
        default:
            return .object([:])
        }
    }

    func release(_ path: String) {
        if let c = held.withLock({ $0.removeValue(forKey: path) }) { c.resume() } else { preReleased.withLock { _ = $0.insert(path) } }
    }

    @MainActor func model() -> BrowserPanelModel {
        BrowserPanelModel(
            request: { [self] m, p in try await self.request(m, p) },
            hasAdmin: { true },
            makeSource: { [self] ticket in
                let s = FakeBrowserSource(ticket: ticket)
                self.sources.withLock { $0.append(s) }
                return s
            },
            debounce: .milliseconds(5), retryDelay: .milliseconds(50))
    }
}

@MainActor
private func controlsEventually(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func rpc(code: String = "UNAVAILABLE", message: String = "failed", details: String? = nil) -> GatewayError {
    .rpc(code: code, message: message, details: details.map { Fixtures.json($0) })
}

@MainActor
struct BrowserErrorClassificationTests {
    @Test func evaluateDisabledByStructuredCode() {
        #expect(BrowserPanelModel.isEvaluateDisabled(rpc(details: #"{"code":"ACT_EVALUATE_DISABLED"}"#)))
        #expect(!BrowserPanelModel.isEvaluateDisabled(rpc(details: #"{"code":"OTHER"}"#)))
    }

    @Test func evaluateDisabledByMessageOnlyWithoutACode() {
        #expect(BrowserPanelModel.isEvaluateDisabled(rpc(message: "browser.evaluateEnabled=false")))
        #expect(!BrowserPanelModel.isEvaluateDisabled(rpc(message: "browser.evaluateEnabled=false", details: #"{"code":"OTHER"}"#)))
        #expect(!BrowserPanelModel.isEvaluateDisabled(rpc(message: "timed out")))
        #expect(!BrowserPanelModel.isEvaluateDisabled(URLError(.timedOut)))
    }

    @Test func navigationBlockedReason() {
        #expect(BrowserPanelModel.isNavigationBlocked(rpc(details: #"{"reason":"navigation_blocked"}"#)))
        #expect(!BrowserPanelModel.isNavigationBlocked(rpc(details: #"{"reason":"other"}"#)))
        #expect(!BrowserPanelModel.isNavigationBlocked(rpc()))
        #expect(!BrowserPanelModel.isNavigationBlocked(URLError(.badURL)))
    }

    @Test func safeFilenames() {
        #expect(BrowserPanelModel.safeFilename("../../etc/passwd") == "passwd")
        #expect(BrowserPanelModel.safeFilename("a:b\\c.html") == "a_b_c.html")
        #expect(BrowserPanelModel.safeFilename(".hidden") == "hidden")
        #expect(BrowserPanelModel.safeFilename(nil) == "page.html")
        #expect(BrowserPanelModel.safeFilename("   ") == "page.html")
        #expect(BrowserPanelModel.safeFilename(String(repeating: "x", count: 500)).count == 200)
    }
}

@MainActor
struct BrowserControlsTests {
    private func readyModel(_ gateway: ControlsGateway) async -> BrowserPanelModel {
        let model = gateway.model()
        await model.refreshTabs()
        model.select(targetId: "T1")
        return model
    }

    @Test func navigateSendsTheNormalisedURLAndTheSelectedTab() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        await model.navigate(to: "docs.openclaw.ai")
        let body = gateway.bodies("/navigate").last ?? nil
        #expect(body?["url"]?.string == "https://docs.openclaw.ai")
        #expect(body?["targetId"]?.string == "T1")
        #expect(!model.isNavigating)
        #expect(model.actionError == nil)
    }

    @Test func anInvalidAddressSendsNothingAndSetsOneLine() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        for bad in ["javascript:alert(1)", "foo", "user:pass@example.com", ""] {
            await model.navigate(to: bad)
            #expect(model.actionError == "Enter a web address", "\(bad)")
        }
        #expect(gateway.count("POST", "/navigate") == 0)
    }

    @Test func blockedAddressMapsToTheFixedText() async {
        let gateway = ControlsGateway()
        gateway.failures.withLock { $0["/navigate"] = rpc(details: #"{"reason":"navigation_blocked"}"#) }
        let model = await readyModel(gateway)
        await model.navigate(to: "blocked.example")
        #expect(model.actionError == "This address is blocked by the gateway's browser policy.")
        #expect(!model.isNavigating)
    }

    @Test func historySendsOnlyTheTwoExactScripts() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        await model.goBack()
        await model.goForward()
        let fns = gateway.bodies("/act").compactMap { $0?["fn"]?.string }
        #expect(fns == ["() => { history.go(-1); return true; }", "() => { history.go(1); return true; }"])
        #expect(gateway.bodies("/act").allSatisfy { $0?["kind"]?.string == "evaluate" && $0?["targetId"]?.string == "T1" })
    }

    @Test func historyStaysEnabledUntilTheFirstRefusalThenStopsSending() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        await model.goBack()
        #expect(!model.historyUnavailable, "enabled until the gateway refuses")
        gateway.failures.withLock { $0["/act"] = rpc(details: #"{"code":"ACT_EVALUATE_DISABLED"}"#) }
        await model.goBack()
        #expect(model.historyUnavailable)
        #expect(model.actionError == nil, "the refusal is shown by the disabled buttons, not as an error")
        let sent = gateway.count("POST", "/act")
        await model.goForward()
        await model.goBack()
        #expect(gateway.count("POST", "/act") == sent, "no more history requests once refused")
    }

    @Test func aReconnectResetsTheHistoryFlag() async {
        let gateway = ControlsGateway()
        gateway.failures.withLock { $0["/act"] = rpc(details: #"{"code":"ACT_EVALUATE_DISABLED"}"#) }
        let model = await readyModel(gateway)
        await model.goBack()
        #expect(model.historyUnavailable)
        model.handleReconnect()
        #expect(!model.historyUnavailable)
    }

    @Test func reloadReNavigatesToTheCurrentURL() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        await model.reload()
        let body = gateway.bodies("/navigate").last ?? nil
        #expect(body?["url"]?.string == "https://one.test/")
        #expect(body?["targetId"]?.string == "T1")
    }

    @Test func aTargetIdChangeFollowsThePageAndRefreshesTabs() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        let tabsBefore = gateway.count("GET", "/tabs")
        gateway.navigateIds.withLock { $0 = ["T9"] }
        gateway.tabsJSON.withLock { $0 = #"[{"targetId":"T9","title":"Moved","url":"https://moved.test/"},{"targetId":"T2","title":"Two","url":"https://two.test/"}]"# }
        await model.navigate(to: "moved.test")
        #expect(model.selectedTargetId == "T9")
        #expect(gateway.count("GET", "/tabs") > tabsBefore, "tabs are refreshed after a navigate")
    }

    @Test func aSupersededNavigateNeitherClearsNavigatingNorSetsAnError() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        gateway.holdNext.withLock { $0.insert("/navigate") }
        gateway.failures.withLock { $0["/navigate"] = rpc(details: #"{"reason":"navigation_blocked"}"#) }
        let first = Task { await model.navigate(to: "first.test") }
        #expect(await controlsEventually { gateway.count("POST", "/navigate") == 1 })
        gateway.failures.withLock { $0["/navigate"] = nil }
        await model.navigate(to: "second.test")
        #expect(!model.isNavigating)
        gateway.failures.withLock { $0["/navigate"] = rpc(details: #"{"reason":"navigation_blocked"}"#) }
        gateway.release("/navigate")
        await first.value
        #expect(model.actionError == nil, "the stale failure is dropped: latest wins")
        #expect(!model.isNavigating)
    }

    @Test func navigatesOnDifferentTabsDoNotSupersedeEachOther() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        gateway.holdNext.withLock { $0.insert("/navigate") }
        let first = Task { await model.navigate(to: "first.test") }
        #expect(await controlsEventually { gateway.count("POST", "/navigate") == 1 })
        model.select(targetId: "T2")
        await model.navigate(to: "second.test")
        gateway.release("/navigate")
        await first.value
        #expect(gateway.count("POST", "/navigate") == 2)
    }

    @Test func openTabSwitchesToTheNewTab() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        gateway.tabsJSON.withLock { $0 = #"[{"targetId":"T1","title":"One","url":"https://one.test/"},{"targetId":"T3","title":"New","url":"https://new.test/"}]"# }
        await model.openTab(url: "new.test")
        #expect((gateway.bodies("/tabs/open").last ?? nil)?["url"]?.string == "https://new.test")
        #expect(model.selectedTargetId == "T3")
    }

    @Test func openTabRejectsABadAddressWithoutAskingTheGateway() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        await model.openTab(url: "file:///etc/passwd")
        #expect(gateway.count("POST", "/tabs/open") == 0)
        #expect(model.actionError == "Enter a web address")
    }

    @Test func closeTabPercentEncodesTheIdAndSelectsANeighbour() async {
        let gateway = ControlsGateway()
        gateway.tabsJSON.withLock { $0 = #"[{"targetId":"A/B 1","title":"One","url":"https://one.test/"},{"targetId":"T2","title":"Two","url":"https://two.test/"}]"# }
        let model = gateway.model()
        await model.refreshTabs()
        model.select(targetId: "A/B 1")
        gateway.tabsJSON.withLock { $0 = #"[{"targetId":"T2","title":"Two","url":"https://two.test/"}]"# }
        await model.closeTab("A/B 1")
        let call = gateway.calls.withLock { $0.last { $0.method == "DELETE" } }
        #expect(call?.path == "/tabs/A%2FB%201")
        #expect(call?.body == nil)
        #expect(model.selectedTargetId == "T2")
    }

    @Test func closingTheMiddleOfThreeSelectsTheNextAndTheLastSelectsThePrevious() async {
        let three = #"[{"targetId":"A","title":"A","url":"https://a.test/"},{"targetId":"B","title":"B","url":"https://b.test/"},{"targetId":"C","title":"C","url":"https://c.test/"}]"#
        let gateway = ControlsGateway()
        gateway.tabsJSON.withLock { $0 = three }
        let model = gateway.model()
        await model.refreshTabs()
        model.select(targetId: "B")
        gateway.tabsJSON.withLock { $0 = #"[{"targetId":"A","title":"A","url":"https://a.test/"},{"targetId":"C","title":"C","url":"https://c.test/"}]"# }
        await model.closeTab("B")
        #expect(model.selectedTargetId == "C", "the middle tab closes onto the next one")

        let gateway2 = ControlsGateway()
        gateway2.tabsJSON.withLock { $0 = three }
        let model2 = gateway2.model()
        await model2.refreshTabs()
        model2.select(targetId: "C")
        gateway2.tabsJSON.withLock { $0 = #"[{"targetId":"A","title":"A","url":"https://a.test/"},{"targetId":"B","title":"B","url":"https://b.test/"}]"# }
        await model2.closeTab("C")
        #expect(model2.selectedTargetId == "B", "the last tab closes onto the previous one")
    }

    @Test func closingAnUnselectedTabKeepsTheSelection() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        gateway.tabsJSON.withLock { $0 = #"[{"targetId":"T1","title":"One","url":"https://one.test/"}]"# }
        await model.closeTab("T2")
        #expect(model.selectedTargetId == "T1")
    }

    @Test func closingTheLastTabLeavesNoSelection() async {
        let gateway = ControlsGateway()
        gateway.tabsJSON.withLock { $0 = #"[{"targetId":"T1","title":"One","url":"https://one.test/"}]"# }
        let model = gateway.model()
        await model.refreshTabs()
        model.select(targetId: "T1")
        gateway.tabsJSON.withLock { $0 = "[]" }
        await model.closeTab("T1")
        #expect(model.selectedTargetId == nil)
        #expect(model.tabs.isEmpty)
    }

    @Test func startBrowserPostsStartThenReloadsTabs() async {
        let gateway = ControlsGateway()
        let model = gateway.model()
        await model.startBrowser()
        #expect(gateway.count("POST", "/start") == 1)
        #expect(gateway.count("GET", "/tabs") >= 1)
        #expect(!model.isNavigating)
    }

    @Test func controlsAreNoOpsWithoutAdmin() async {
        let gateway = ControlsGateway()
        let admin = Mutex(true)
        let model = BrowserPanelModel(request: { m, p in try await gateway.request(m, p) },
                                      hasAdmin: { admin.withLock { $0 } },
                                      makeSource: { _ in nil })
        await model.refreshTabs()
        model.select(targetId: "T1")
        admin.withLock { $0 = false }
        let before = gateway.calls.withLock { $0.count }
        await model.navigate(to: "example.com")
        await model.reload()
        await model.goBack()
        await model.openTab(url: "example.com")
        await model.closeTab("T1")
        await model.startBrowser()
        #expect(gateway.calls.withLock { $0.count } == before)
    }

    @Test func aNewActionClearsThePreviousError() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        await model.navigate(to: "nope")
        #expect(model.actionError != nil)
        await model.navigate(to: "ok.test")
        #expect(model.actionError == nil)
    }

    @Test func downloadRequestsTheCurrentDocumentWithItsURL() async throws {
        let gateway = ControlsGateway()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("raw")
        try Data("<html>hi</html>".utf8).write(to: source)
        let model = BrowserPanelModel(
            request: { m, p in
                if p["path"]?.string == "/download" {
                    _ = try await gateway.request(m, p)
                    return Fixtures.json(#"{"download":{"path":"/x/y.html","suggestedFilename":"../a:b.html"}}"#)
                }
                return try await gateway.request(m, p)
            },
            hasAdmin: { true }, makeSource: { _ in nil }, fetchDownload: { path in
                #expect(path == "/x/y.html")
                let copy = dir.appendingPathComponent("raw-\(UUID().uuidString)")
                try FileManager.default.copyItem(at: source, to: copy)
                return copy
            })
        await model.refreshTabs()
        model.select(targetId: "T1")
        let file = try await model.downloadCurrentPage()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.lastPathComponent == "a_b.html")
        #expect(file.deletingLastPathComponent().lastPathComponent.hasPrefix("pincer-browser-"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "<html>hi</html>")
        let body = gateway.bodies("/download").last ?? nil
        #expect(body?["currentDocument"]?.bool == true)
        #expect(body?["expectedUrl"]?.string == "https://one.test/")
        #expect(body?["targetId"]?.string == "T1")
        #expect(!model.isDownloading)
    }

    @Test func downloadCancelThrowsCancellationAndSetsNoError() async throws {
        let gateway = ControlsGateway()
        gateway.holdNext.withLock { $0.insert("/download") }
        let model = BrowserPanelModel(
            request: { m, p in
                let reply = try await gateway.request(m, p)
                return p["path"]?.string == "/download" ? Fixtures.json(#"{"download":{"path":"/x","suggestedFilename":"a.html"}}"#) : reply
            },
            hasAdmin: { true }, makeSource: { _ in nil }, fetchDownload: { _ in try Task.checkCancellation(); throw URLError(.cancelled) })
        await model.refreshTabs()
        model.select(targetId: "T1")
        let task = Task { try await model.downloadCurrentPage() }
        #expect(await controlsEventually { model.isDownloading })
        #expect(await controlsEventually { gateway.held.withLock { $0["/download"] != nil } })
        model.cancelDownload()
        gateway.release("/download")
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!model.isDownloading)
        #expect(model.actionError == nil)
    }

    @Test func downloadWithoutAFetcherFails() async {
        let gateway = ControlsGateway()
        let model = await readyModel(gateway)
        await #expect(throws: BrowserPanelModel.ActionError.self) { try await model.downloadCurrentPage() }
    }
}
