import Foundation

/// Browser controls (navigate, reload, history, tabs, start, download). Each is a `browser.request`
/// that needs `operator.admin`, like the view. Only these scripts are ever sent to the page:
/// `history.go(-1)` and `history.go(1)`.
extension BrowserPanelModel {
    public enum ActionError: Error, Equatable, Sendable {
        case noPage, noDownload, failed
    }

    // MARK: Navigation

    /// `POST /navigate`. `draft` is what was typed; anything that isn't a web address sets `actionError`.
    public func navigate(to draft: String) async {
        guard let url = BrowserURLDraft.normalize(draft) else {
            self.fail(L("Enter a web address"))
            return
        }
        await self.go(to: url.absoluteString)
    }

    /// Re-navigates to the current address. A bare frame refresh would leave the remote page untouched.
    public func reload() async {
        guard let url = self.pageURL ?? self.selectedTab?.url else { return }
        await self.go(to: url.absoluteString)
    }

    public func goBack() async { await self.history(-1) }
    public func goForward() async { await self.history(1) }

    private func go(to url: String) async {
        guard let tab = self.actionTab() else { return }
        let token = self.nextToken(tab.targetId)
        self.actionError = nil
        self.isNavigating = true
        do {
            let reply = try await self.request("browser.request", Self.envelope(
                "POST", "/navigate", route: tab.route,
                body: ["url": .string(url), "targetId": .string(tab.targetId)]))
            guard self.isLatest(token, tab.targetId) else { return }
            self.isNavigating = false
            let newId = reply["targetId"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? tab.targetId
            if let next = URL(string: reply["url"]?.string ?? url), BrowserTabRef.webURL(next) != nil, next != self.pageURL {
                self.pageURL = next
            }
            await self.settle(from: tab.targetId, to: newId)
        } catch {
            guard self.isLatest(token, tab.targetId) else { return }
            self.isNavigating = false
            self.fail(self.message(for: error))
        }
    }

    /// `history.go(±1)` through `/act evaluate`, as the Control UI does. Turned off for this Gateway when evaluate is disabled.
    private func history(_ delta: Int) async {
        guard !self.historyUnavailable, delta == -1 || delta == 1, let tab = self.actionTab() else { return }
        let token = self.nextToken(tab.targetId)
        self.actionError = nil
        self.isNavigating = true
        do {
            _ = try await self.request("browser.request", Self.envelope(
                "POST", "/act", route: tab.route,
                body: ["kind": "evaluate", "targetId": .string(tab.targetId),
                       "fn": .string("() => { history.go(\(delta)); return true; }")]))
            guard self.isLatest(token, tab.targetId) else { return }
            self.isNavigating = false
            await self.settle(from: tab.targetId, to: tab.targetId)
        } catch {
            guard self.isLatest(token, tab.targetId) else { return }
            self.isNavigating = false
            if Self.isEvaluateDisabled(error) {
                self.historyUnavailable = true
            } else {
                self.fail(self.message(for: error))
            }
        }
    }

    // MARK: Tabs and the browser

    /// `POST /tabs/open`, then shows the new tab.
    public func openTab(url draft: String) async {
        guard self.hasAdmin, let url = BrowserURLDraft.normalize(draft) else {
            if self.hasAdmin { self.fail(L("Enter a web address")) }
            return
        }
        let token = self.nextToken("")
        self.actionError = nil
        self.isNavigating = true
        let route = self.route
        do {
            let reply = try await self.request("browser.request", Self.envelope(
                "POST", "/tabs/open", route: route, body: ["url": .string(url.absoluteString)]))
            guard self.isLatest(token, "") else { return }
            self.isNavigating = false
            guard var tab = BrowserPageTab.parse(row: reply, route: route) else {
                _ = await self.fetchTabs()
                return
            }
            if tab.url == nil { tab.url = BrowserTabRef.webURL(url) }
            if !self.tabs.contains(where: { $0.targetId == tab.targetId }) { self.tabs.append(tab) }
            self.selectedPageMissing = false
            self.pageSelectionChanged(to: tab.targetId, title: tab.title, url: tab.url)
            _ = await self.fetchTabs()
        } catch {
            guard self.isLatest(token, "") else { return }
            self.isNavigating = false
            self.fail(self.message(for: error))
        }
    }

    /// `DELETE /tabs/<id>`. Shows another tab if the closed one was selected.
    public func closeTab(_ targetId: String) async {
        guard self.hasAdmin, let tab = self.tabs.first(where: { $0.targetId == targetId }) else { return }
        let token = self.nextToken(targetId)
        self.actionError = nil
        do {
            let encoded = targetId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? targetId
            _ = try await self.request("browser.request", Self.envelope(
                "DELETE", "/tabs/\(encoded)", route: tab.route, body: nil))
            guard self.isLatest(token, targetId) else { return }
            let closedIndex = self.tabs.firstIndex { $0.targetId == targetId } ?? 0
            self.tabs.removeAll { $0.targetId == targetId }
            self.clearThumbnail(for: tab)
            if self.selectedTargetId == targetId {
                if !self.tabs.isEmpty {
                    let next = self.tabs[min(closedIndex, self.tabs.count - 1)]
                    self.selectedPageMissing = false
                    self.pageSelectionChanged(to: next.targetId, title: next.title, url: next.url)
                } else {
                    self.selectedTargetId = nil
                    self.frame = nil
                    self.pageTitle = nil
                    self.pageURL = nil
                    self.cancelStream()
                    self.setStatus(.idle)
                }
            }
            _ = await self.fetchTabs()
        } catch {
            guard self.isLatest(token, targetId) else { return }
            self.fail(self.message(for: error))
        }
    }

    /// `POST /start`, used when the browser isn't running.
    public func startBrowser() async {
        guard self.hasAdmin else { return }
        self.actionError = nil
        self.isNavigating = true
        defer { self.isNavigating = false }
        do {
            _ = try await self.request("browser.request", Self.envelope("POST", "/start", route: self.route, body: [:]))
            self.tabsLoaded = false
            await self.refreshTabs()
        } catch {
            self.fail(self.message(for: error))
        }
    }

    // MARK: Download

    /// `POST /download` for the current page, then the saved file's bytes through the Gateway's media route,
    /// into a temporary file (written off the main actor). Cancellable with `cancelDownload()` or by
    /// cancelling the calling task. The caller owns the returned file.
    public func downloadCurrentPage() async throws -> URL {
        guard let tab = self.actionTab(), let fetch = self.fetchDownload else { throw ActionError.noPage }
        guard !self.isDownloading else { throw ActionError.failed }
        self.actionError = nil
        self.isDownloading = true
        let url = self.pageURL ?? tab.url
        let request = self.request
        let task = Task<URL, Error> {
            let reply = try await request("browser.request", Self.envelope(
                "POST", "/download", route: tab.route,
                body: ["targetId": .string(tab.targetId), "currentDocument": true,
                       "expectedUrl": url.map { .string($0.absoluteString) } ?? .null, "timeoutMs": 120_000])
                .adding("timeoutMs", 150_000))
            guard let path = reply["download"]?["path"]?.string, !path.isEmpty else { throw ActionError.noDownload }
            let name = Self.safeFilename(reply["download"]?["suggestedFilename"]?.string)
            let file = try await fetch(path)
            return try await Task.detached(priority: .utility) { try Self.place(file, name: name) }.value
        }
        self.downloadTask = task
        defer {
            self.downloadTask = nil
            self.isDownloading = false
        }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if !(error is CancellationError), !Task.isCancelled { self.fail(self.downloadMessage(error)) }
            throw error
        }
    }

    public func cancelDownload() {
        self.downloadTask?.cancel()
    }

    // MARK: Classification

    /// The Gateway refused the address (`details.reason == "navigation_blocked"`).
    public static func isNavigationBlocked(_ error: Error) -> Bool {
        guard case let .rpc(_, _, details) = error as? GatewayError else { return false }
        return details?["reason"]?.string == "navigation_blocked" || details?["body"]?["reason"]?.string == "navigation_blocked"
    }

    /// `browser.evaluateEnabled=false`, as upstream's `isBrowserEvaluateDisabledError` reads it: a structured
    /// code must be `ACT_EVALUATE_DISABLED`; without one, the message must say `evaluateEnabled=false`.
    public static func isEvaluateDisabled(_ error: Error) -> Bool {
        guard case let .rpc(_, message, details) = error as? GatewayError else { return false }
        let code = details?["code"]
        let structured = code != nil || details?["unrecognizedCode"]?.bool == true
        return structured ? code?.string == "ACT_EVALUATE_DISABLED" : message.contains("evaluateEnabled=false")
    }

    // MARK: Helpers

    private func actionTab() -> BrowserPageTab? {
        guard self.hasAdmin, !self.selectedPageMissing else { return nil }
        return self.selectedTab
    }

    private func nextToken(_ key: String) -> Int {
        let next = (self.mutationTokens[key] ?? 0) + 1
        self.mutationTokens[key] = next
        return next
    }

    private func isLatest(_ token: Int, _ key: String) -> Bool {
        self.mutationTokens[key] == token
    }

    /// After a mutation: reload the tab list, and follow the page if it moved to a new `targetId`.
    private func settle(from oldId: String, to newId: String) async {
        let moved = newId != oldId && self.selectedTargetId == oldId
        if moved {
            self.selectedTargetId = newId
            self.frame = nil
        }
        _ = await self.fetchTabs()
        if self.visible, moved || !self.streamRunning { self.restartStream() }
    }

    private func message(for error: Error) -> String {
        if Self.isNavigationBlocked(error) { return L("This address is blocked by the gateway's browser policy.") }
        if case GatewayError.notConnected = error { return L("Not connected to the Gateway.") }
        switch GatewayError.classify(error) {
        case .missingScope:
            self.deniedAdmin = true
            return L("The browser needs Full Management.")
        case .unsupported:
            return L("This Gateway can't control its browser.")
        case let .message(text):
            return Self.sanitized(text)
        }
    }

    private func downloadMessage(_ error: Error) -> String {
        if error is ActionError || error is MediaError { return L("Couldn't download this page.") }
        if case GatewayError.timeout = error { return L("The download took too long.") }
        if (error as? URLError)?.code == .timedOut { return L("The download took too long.") }
        if case let GatewayError.rpc(_, message, _) = error, message.localizedCaseInsensitiveContains("expected") {
            return L("The page changed before it could be downloaded.")
        }
        return L("Couldn't download this page.") + " " + self.message(for: error)
    }

    /// Shows one error line and clears it after a few seconds (or sooner, on the next action or tab switch).
    private func fail(_ text: String) {
        self.actionError = text
        self.actionErrorClear?.cancel()
        self.actionErrorClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.actionError = nil
        }
    }

    nonisolated static func safeFilename(_ suggested: String?) -> String {
        let base = (suggested.map { ($0 as NSString).lastPathComponent } ?? "")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.controlCharacters))
        return base.isEmpty ? "page.html" : String(base.prefix(200))
    }

    /// Moves a downloaded temp file into its own directory under the safe name.
    nonisolated static func place(_ file: URL, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    /// Deletes leftover `pincer-browser-*` download folders; call once at launch, off the main actor.
    public nonisolated static func cleanTemporaryDownloads() {
        let temp = FileManager.default.temporaryDirectory
        for url in (try? FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("pincer-browser-") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func writeTemp(_ data: Data, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pincer-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try data.write(to: file, options: .atomic)
        return file
    }
}

private extension JSONValue {
    func adding(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case var .object(object) = self else { return self }
        object[key] = value
        return .object(object)
    }
}
