import CoreGraphics
import Foundation
import Observation

/// The agent's live browser, view-only: the page list (`GET /tabs`) and a screencast of the selected
/// page (`POST /screencast`, then a second WebSocket). Both need `operator.admin` (Full Management).
/// One per `GatewayStore`. The stream runs only while the panel is visible. Socket reads, JPEG
/// decoding and parsing are off the main actor; main only assigns the finished `CGImage`.
///
/// Observation: `frame` changes several times a second, so only the leaf frame view should read it.
/// `pageTitle`, `pageURL` and `status` are assigned only when they change.
@MainActor
@Observable
public final class BrowserPanelModel {
    public enum Status: Equatable, Sendable {
        case idle, loading, live, reconnecting, needsFullManagement, notRunning, navigationBlocked
        case failed(String)
    }

    /// What `POST /screencast` returned, plus the size that was asked for.
    public struct Ticket: Sendable {
        /// Carries a one-time token. Never log it or show it.
        public let wsPath: String
        public let targetId: String
        public let url: String?
        public let maxWidth: Int
        public let maxHeight: Int

        public var maxPixelSize: Int { max(self.maxWidth, self.maxHeight) }
    }

    public typealias Request = @Sendable (_ method: String, _ params: JSONValue) async throws -> JSONValue
    public typealias SourceFactory = @MainActor (Ticket) -> (any BrowserFrameSource)?

    public static let maxStreamWidth = 1600
    public static let maxStreamHeight = 1200

    public private(set) var tabs: [BrowserPageTab] = []
    public private(set) var selectedTargetId: String?
    /// The latest frame. Read only from the leaf view that draws it.
    public private(set) var frame: BrowserFrame?
    public private(set) var pageTitle: String?
    public private(set) var pageURL: URL?
    public private(set) var status: Status = .idle
    /// True once `/tabs` has answered: with `tabs` empty and the browser running, there are no pages open.
    public private(set) var tabsLoaded = false
    /// The selected page (a card's stale reference) isn't in the Gateway's list any more.
    public private(set) var selectedPageMissing = false
    /// Set when a call hit a scope error although the connection claimed `operator.admin`.
    public private(set) var deniedAdmin = false

    @ObservationIgnored private let request: Request
    @ObservationIgnored private let adminCheck: @MainActor () -> Bool
    @ObservationIgnored private let makeSource: SourceFactory
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var route = BrowserRoute()
    @ObservationIgnored private var viewers: [AnyHashable: CGSize] = [:]
    @ObservationIgnored private var visible: Bool { !self.viewers.isEmpty }
    @ObservationIgnored private var pixelSize = CGSize(width: 1280, height: 800)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var streamRunning = false
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    /// Full Management (or the demo).
    public var hasAdmin: Bool { !self.deniedAdmin && self.adminCheck() }

    public var selectedTab: BrowserPageTab? { self.tabs.first { $0.targetId == self.selectedTargetId } }

    /// For checks, tests and previews.
    public init(request: @escaping Request, hasAdmin: @escaping @MainActor () -> Bool = { true },
                makeSource: @escaping SourceFactory, debounce: Duration = .milliseconds(500),
                retryDelay: Duration = .seconds(10))
    {
        self.request = request
        self.adminCheck = hasAdmin
        self.makeSource = makeSource
        self.debounce = debounce
        self.retryDelay = retryDelay
    }

    init(connection: GatewayConnection, profile: @escaping @MainActor () -> GatewayProfile,
         hello: @escaping @MainActor () -> GatewayHello?)
    {
        self.request = { method, params in try await connection.request(method, params, timeout: 30) }
        self.adminCheck = { profile().isDemo || hello()?.scopes.contains(GatewayConnection.adminScope) == true }
        self.makeSource = { ticket in
            if let targetId = BrowserDemoFrameSource.targetId(wsPath: ticket.wsPath) {
                return BrowserDemoFrameSource(targetId: targetId)
            }
            let current = profile()
            guard !current.isDemo, let gateway = try? current.resolvedURL(),
                  let url = BrowserScreencastClient.resolveURL(wsPath: ticket.wsPath, gateway: gateway)
            else { return nil }
            return BrowserScreencastClient(url: url, fingerprint: current.tlsFingerprint, maxPixelSize: ticket.maxPixelSize)
        }
        self.debounce = .milliseconds(500)
        self.retryDelay = .seconds(10)
    }

    // MARK: Public

    /// Reloads the page list, and restarts the stream if it had stopped on an error.
    public func refreshTabs() async {
        guard await self.fetchTabs(), self.visible else { return }
        switch self.status {
        case .failed, .notRunning, .navigationBlocked, .idle: self.restartStream()
        default: if !self.streamRunning { self.restartStream() }
        }
    }

    /// A transcript card asks to show its page. Selects the matching tab, or adds a placeholder from the card.
    /// Does nothing when that page is already selected on the same route.
    public func select(_ ref: BrowserTabRef) {
        let newRoute = ref.profile == nil ? self.route : ref.route
        let sameRoute = newRoute == self.route
        if sameRoute, self.selectedTargetId == ref.targetId {
            if self.visible, !self.streamRunning { self.restartStream() }
            return
        }
        if !sameRoute {
            self.route = newRoute
            self.tabs = []
            self.tabsLoaded = false
        }
        if !self.tabs.contains(where: { $0.targetId == ref.targetId }) {
            self.tabs.append(BrowserPageTab(ref))
        }
        self.selectedPageMissing = false
        self.pageSelectionChanged(to: ref.targetId, title: ref.title, url: ref.url)
    }

    /// Picks one of `tabs` (the page picker).
    public func select(targetId: String) {
        guard let tab = self.tabs.first(where: { $0.targetId == targetId }), targetId != self.selectedTargetId else { return }
        self.route = tab.route
        self.selectedPageMissing = false
        self.pageSelectionChanged(to: targetId, title: tab.title, url: tab.url)
    }

    /// Visibility is per viewer (window or panel instance), so two windows can share the model. The stream
    /// runs while any viewer is visible, at the largest visible size (capped when requested), and stops only when
    /// the last viewer leaves. `pixelSize` is the viewer's frame area in pixels; sizes are debounced (500 ms),
    /// the first one too, so a panel slide doesn't start a burst of streams.
    public func setVisible(_ visible: Bool, pixelSize: CGSize, viewer: AnyHashable = "default") {
        guard visible else {
            guard self.viewers.removeValue(forKey: viewer) != nil else { return }
            if self.viewers.isEmpty {
                self.cancelStream()
                if [.live, .loading, .reconnecting].contains(self.status) { self.status = .idle }
            } else {
                self.applyLargestSize(restartIfChanged: true)
            }
            return
        }
        let wasVisible = self.visible
        let previous = self.pixelSize
        self.viewers[viewer] = pixelSize.width > 0 && pixelSize.height > 0 ? pixelSize : (self.viewers[viewer] ?? previous)
        let sizeChanged = self.applyLargestSize(restartIfChanged: false)
        guard self.hasAdmin else {
            self.cancelStream()
            self.setStatus(.needsFullManagement)
            return
        }
        if wasVisible, !sizeChanged, self.streamRunning || self.debounceTask != nil { return }
        self.scheduleStart()
    }

    @discardableResult
    private func applyLargestSize(restartIfChanged: Bool) -> Bool {
        guard !self.viewers.isEmpty else { return false }
        let width = self.viewers.values.map(\.width).max() ?? self.pixelSize.width
        let height = self.viewers.values.map(\.height).max() ?? self.pixelSize.height
        let changed = abs(width - self.pixelSize.width) > 8 || abs(height - self.pixelSize.height) > 8
        if changed { self.pixelSize = CGSize(width: width, height: height) }
        if changed, restartIfChanged, self.hasAdmin { self.scheduleStart() }
        return changed
    }

    private func scheduleStart() {
        self.setStatus(self.frame == nil ? .loading : .reconnecting)
        self.debounceTask?.cancel()
        self.debounceTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.debounceTask = nil
            self.restartStream()
        }
    }

    /// Stops the stream for every viewer. The last frame stays, so reopening shows it at once.
    public func stop() {
        self.viewers.removeAll()
        self.cancelStream()
        if [.live, .loading, .reconnecting].contains(self.status) { self.status = .idle }
    }

    /// A reconnect may bring new scopes, and the old stream token belonged to the old connection.
    public func handleReconnect() {
        self.deniedAdmin = false
        guard self.visible else { return }
        if self.hasAdmin {
            self.restartStream()
        } else {
            self.cancelStream()
            self.setStatus(.needsFullManagement)
        }
    }

    // MARK: Selection and streaming

    private func pageSelectionChanged(to targetId: String, title: String?, url: URL?) {
        self.selectedTargetId = targetId
        self.frame = nil
        self.pageTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        self.pageURL = url
        guard self.visible else { return }
        if self.hasAdmin {
            self.setStatus(.loading)
            self.restartStream()
        } else {
            self.cancelStream()
            self.setStatus(.needsFullManagement)
        }
    }

    private func cancelStream() {
        self.generation += 1
        self.streamTask?.cancel()
        self.streamTask = nil
        self.streamRunning = false
        self.debounceTask?.cancel()
        self.debounceTask = nil
    }

    private func restartStream() {
        self.cancelStream()
        guard self.visible else { return }
        guard self.hasAdmin else {
            self.setStatus(.needsFullManagement)
            return
        }
        let generation = self.generation
        self.streamRunning = true
        self.streamTask = Task { [weak self] in
            await self?.runStream(generation)
            if let self, self.generation == generation { self.streamRunning = false }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && self.generation == generation && self.visible
    }

    private func runStream(_ generation: Int) async {
        while self.isCurrent(generation) {
            if self.selectedTargetId == nil || !self.tabsLoaded {
                guard await self.fetchTabs(), self.isCurrent(generation) else {
                    if self.isCurrent(generation), self.status.isRetryable {
                        await self.pause(self.retryDelay)
                        continue
                    }
                    return
                }
                if self.status == .notRunning {
                    self.tabsLoaded = false
                    await self.pause(self.retryDelay)
                    continue
                }
            }
            if self.tabs.isEmpty {
                // Running with no pages: look again later, so a page the agent opens shows up.
                self.setStatus(.idle)
                self.tabsLoaded = false
                await self.pause(self.retryDelay)
                continue
            }
            guard let tab = self.selectedTab ?? self.tabs.first, !self.selectedPageMissing else {
                self.setStatus(.idle)
                return
            }
            if self.selectedTargetId == nil { self.selectedTargetId = tab.targetId }
            self.setStatus(self.frame == nil ? .loading : .reconnecting)
            let outcome = await self.stream(tab, generation: generation)
            guard self.isCurrent(generation) else { return }
            switch outcome {
            case .stop: return
            case .refreshTabs:
                _ = await self.fetchTabs()
            case let .retry(delay):
                self.setStatus(.reconnecting)
                await self.pause(delay)
            }
        }
    }

    private enum Outcome { case stop, refreshTabs, retry(Duration) }

    private func stream(_ tab: BrowserPageTab, generation: Int) async -> Outcome {
        let width = max(1, min(Int(self.pixelSize.width.rounded()), Self.maxStreamWidth))
        let height = max(1, min(Int(self.pixelSize.height.rounded()), Self.maxStreamHeight))
        let reply: JSONValue
        do {
            reply = try await self.request("browser.request", Self.envelope(
                "POST", "/screencast", route: tab.route,
                body: ["targetId": .string(tab.targetId), "maxWidth": .number(Double(width)),
                       "maxHeight": .number(Double(height))]))
        } catch {
            guard self.isCurrent(generation) else { return .stop }
            return self.handleFailure(error)
        }
        guard self.isCurrent(generation) else { return .stop }
        guard let wsPath = reply["wsPath"]?.text, reply["token"]?.text != nil else {
            self.setStatus(.failed(L("The Gateway sent an unreadable browser stream reply.")))
            return .retry(self.retryDelay)
        }
        let ticket = Ticket(wsPath: wsPath, targetId: tab.targetId, url: reply["url"]?.string, maxWidth: width, maxHeight: height)
        guard let source = self.makeSource(ticket) else {
            self.setStatus(.failed(L("The Gateway's browser stream address isn't usable.")))
            return .retry(self.retryDelay)
        }
        var gotFrame = false
        var closeCode: Int?
        do {
            for try await event in source.frames() {
                guard self.isCurrent(generation) else { return .stop }
                switch event {
                case let .frame(next):
                    gotFrame = true
                    self.frame = next
                    self.setStatus(.live)
                    self.setPage(title: nil, url: next.pageURL)
                case let .meta(url, title):
                    self.setPage(title: title, url: url)
                case let .closed(code):
                    closeCode = code
                }
            }
        } catch {
            guard self.isCurrent(generation) else { return .stop }
            self.setStatus(.reconnecting)
        }
        guard self.isCurrent(generation) else { return .stop }
        switch closeCode {
        case 4003:
            self.setStatus(.navigationBlocked)
            return .stop
        case 4004:
            return .refreshTabs
        default:
            return .retry(gotFrame ? self.retryDelay / 10 : self.retryDelay)
        }
    }

    private func handleFailure(_ error: Error) -> Outcome {
        switch GatewayError.classify(error) {
        case .missingScope:
            self.deniedAdmin = true
            self.setStatus(.needsFullManagement)
            return .stop
        case .unsupported:
            self.setStatus(.failed(L("This Gateway can't show its browser. Update OpenClaw to use the browser panel.")))
            return .stop
        case let .message(text):
            if case GatewayError.notConnected = error {
                self.setStatus(.reconnecting)
            } else if Self.isScreencastUnsupported(error) {
                self.setStatus(.failed(L("This browser can't be streamed.")))
                return .stop
            } else {
                self.setStatus(.failed(Self.sanitized(text)))
            }
            return .retry(self.retryDelay)
        }
    }

    private func pause(_ delay: Duration) async {
        try? await Task.sleep(for: delay)
    }

    // MARK: Tabs

    /// `GET /tabs`. False when the call failed (the status says why).
    private func fetchTabs() async -> Bool {
        guard self.hasAdmin else {
            self.setStatus(.needsFullManagement)
            return false
        }
        let route = self.route
        do {
            let reply = try await self.request("browser.request", Self.envelope("GET", "/tabs", route: route, body: nil))
            guard route == self.route else { return false }
            let parsed = BrowserPageTab.parseList(reply, route: route)
            self.tabsLoaded = true
            guard parsed.running else {
                if !self.tabs.isEmpty { self.tabs = [] }
                self.selectedPageMissing = false
                self.setStatus(.notRunning)
                return true
            }
            var next = parsed.tabs
            if let selected = self.selectedTargetId, !next.contains(where: { $0.targetId == selected }) {
                self.selectedPageMissing = true
                next.append(self.selectedTab ?? BrowserPageTab(targetId: selected, route: route))
            } else {
                self.selectedPageMissing = false
                if self.selectedTargetId == nil, let first = next.first { self.selectedTargetId = first.targetId }
            }
            if next != self.tabs { self.tabs = next }
            if self.status == .notRunning || self.status == .needsFullManagement { self.setStatus(.idle) }
            return true
        } catch {
            if _isCancellation(error) { return false }
            switch self.handleFailure(error) {
            case .stop, .refreshTabs, .retry: return false
            }
        }
    }

    // MARK: Helpers

    private func setStatus(_ next: Status) {
        if self.status != next { self.status = next }
    }

    private func setPage(title: String?, url: URL?) {
        if let title, !title.isEmpty, title != self.pageTitle { self.pageTitle = title }
        if let url, url != self.pageURL { self.pageURL = url }
    }

    /// `browser.request`: method, path, body and timeout, routed like upstream's `bindBrowserRequestClient`:
    /// `target` and `node` at the top, `profile` in `query`.
    static func envelope(_ method: String, _ path: String, route: BrowserRoute, body: JSONValue?) -> JSONValue {
        var params: [String: JSONValue] = ["method": .string(method), "path": .string(path)]
        if let target = route.target {
            params["target"] = .string(target)
            if target == "node", let node = route.node { params["node"] = .string(node) }
        }
        if let profile = route.profile { params["query"] = ["profile": .string(profile)] }
        if let body { params["body"] = body }
        return .object(params)
    }

    private static func isScreencastUnsupported(_ error: Error) -> Bool {
        guard case let .rpc(_, _, details) = error as? GatewayError else { return false }
        return details?["code"]?.string == "SCREENCAST_UNSUPPORTED" || details?["body"]?["code"]?.string == "SCREENCAST_UNSUPPORTED"
    }

    /// An error message with anything that could carry the screencast address or its one-time token removed.
    public static func sanitized(_ text: String) -> String {
        var clean = text.replacing(/[A-Za-z][A-Za-z0-9+.\-]*:\/\/\S*/, with: "…")
        clean = clean.replacing(/\S*\/browser\/screencast\S*/, with: "…")
        clean = clean.replacing(/(?i)\S*(token|wspath)\S*/, with: "…")
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 200 { clean = String(clean.prefix(200)) + "…" }
        return clean.isEmpty ? L("The browser stream failed.") : clean
    }
}

private extension BrowserPanelModel.Status {
    var isRetryable: Bool {
        switch self {
        case .failed, .reconnecting, .notRunning: true
        default: false
        }
    }
}

private func _isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}
