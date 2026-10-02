import Foundation

/// A message to scroll to once its chat is on screen.
public struct MessageJump: Hashable, Sendable {
    public let id: UUID
    public let target: Notifier.Target
    public let messageId: String

    public init(target: Notifier.Target, messageId: String) {
        self.id = UUID()
        self.target = target
        self.messageId = messageId
    }
}

/// A passing, non-blocking note about a link that couldn't be followed as asked.
public struct RouteNotice: Hashable, Sendable {
    public let id: UUID
    public let message: String

    public init(_ message: String) {
        self.id = UUID()
        self.message = message
    }
}

// MARK: Routing

/// Every way into a chat from outside the window (links, Handoff, notifications, shortcuts, the
/// menu bar) goes through `open(_ route:)`. It only navigates: nothing is sent or approved.
extension AppModel {
    /// Follows `route`, returning what it resolved to. Unknown gateways or chats leave a
    /// `routeNotice` instead of failing. Pass `verifySession: false` for routes Pincer made itself
    /// (notifications, menu bar, palette, shortcuts, search): their chat may not be listed yet.
    /// Links and Handoff keep the default, so a chat that's gone says so.
    @discardableResult
    public func open(_ route: PincerRoute, verifySession: Bool = true) -> PincerRoute.Resolution {
        self.cancelPendingExternalRoute()
        let resolution = route.resolve(in: self.gateways, verifySession: verifySession, preferring: self.selectedGatewayId)
        if verifySession, self.shouldWaitForGatewayDiscovery(route, resolution: resolution,
                                                             waitForProvisionalHolder: false) {
            self.deferExternalRoute(route)
            return resolution
        }
        return self.apply(route, resolution: resolution, verifySession: verifySession)
    }

    private func apply(_ route: PincerRoute, resolution: PincerRoute.Resolution,
                       verifySession: Bool) -> PincerRoute.Resolution {
        switch resolution {
        case let .openChat(target, messageId):
            self.messageJump = messageId.map { MessageJump(target: target, messageId: $0) }
            self.open(target)
            if let gateway = self.gateways.first(where: { $0.id == target.gatewayId }) {
                gateway.revealInSidebar(gateway.resolveSessionKey(target.sessionKey))
            }
        case let .openGateway(id):
            self.open(Notifier.Target(gatewayId: id, sessionKey: ""))
        case .openDemo:
            self.openDemo()
            // Now saved, the demo resolves like any gateway.
            if self.gateways.contains(where: \.profile.isDemo) { return self.open(route, verifySession: verifySession) }
        case .unknownGateway:
            self.gatewayListRequests += 1
            self.routeNotice = RouteNotice(PincerRoute.Notice.unknownGateway)
        case let .unknownSession(gatewayId, _):
            self.open(Notifier.Target(gatewayId: gatewayId, sessionKey: ""))
            self.routeNotice = RouteNotice(PincerRoute.Notice.unknownSession)
        }
        return resolution
    }

    private func shouldWaitForGatewayDiscovery(_ route: PincerRoute, resolution: PincerRoute.Resolution,
                                               waitForProvisionalHolder: Bool) -> Bool {
        guard route.gateway != .demo else { return false }
        let candidates = self.gateways.filter { !$0.profile.isDemo }
        guard !candidates.isEmpty, candidates.contains(where: { !$0.sessionListReady }) else { return false }
        switch resolution {
        case .unknownGateway:
            return true
        case let .openChat(target, _):
            guard waitForProvisionalHolder else { return false }
            guard let gateway = candidates.first(where: { $0.id == target.gatewayId }) else { return false }
            let candidate = PincerRoute.Candidate(id: gateway.id, isDemo: gateway.profile.isDemo,
                                                  sessionKeys: gateway.sessionListReady ? Set(gateway.sessions.keys) : nil,
                                                  url: gateway.profile.url, gatewayHost: gateway.gatewayHost)
            // Exact id or known address is already enough to navigate; only a provisional
            // unique-holder match waits for every saved list so a later duplicate can disambiguate.
            return !route.directlyMatches(candidate)
        default:
            return false
        }
    }

    private func deferExternalRoute(_ route: PincerRoute) {
        let token = UUID()
        self.pendingExternalRoute = route
        self.pendingExternalRouteToken = token
        let timeout = self.pendingExternalRouteTimeout
        self.pendingExternalRouteTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled else { return }
            self?.finishPendingExternalRoute(token: token)
        }
    }

    func cancelPendingExternalRoute() {
        self.pendingExternalRouteTask?.cancel()
        self.pendingExternalRouteTask = nil
        self.pendingExternalRoute = nil
        self.pendingExternalRouteToken = nil
    }

    func installRouteCandidateObserver(for gateway: GatewayStore) {
        gateway.routeCandidatesDidChange = { [weak self, weak gateway] in
            guard let self, let gateway,
                  self.gateways.contains(where: { $0 === gateway })
            else { return }
            self.retryPendingExternalRouteIfNeeded()
        }
    }

    func retryPendingExternalRouteIfNeeded() {
        guard let token = self.pendingExternalRouteToken else { return }
        self.finishPendingExternalRoute(token: token, onlyIfReady: true)
    }

    private func finishPendingExternalRoute(token: UUID, onlyIfReady: Bool = false) {
        guard token == self.pendingExternalRouteToken, let route = self.pendingExternalRoute else { return }
        let resolution = route.resolve(in: self.gateways, verifySession: true, preferring: self.selectedGatewayId)
        if onlyIfReady,
           self.shouldWaitForGatewayDiscovery(route, resolution: resolution, waitForProvisionalHolder: true) { return }
        self.cancelPendingExternalRoute()
        _ = self.apply(route, resolution: resolution, verifySession: true)
    }

    /// Deterministic completion seam for tests using a zero route deadline.
    func waitForPendingExternalRouteResolution() async {
        await self.pendingExternalRouteTask?.value
    }

    /// Follows `route` and opens Find in the chat on `query`, `match` (if given) selected, e.g.
    /// for a message search result.
    @discardableResult
    public func open(_ route: PincerRoute, find query: String, match: TranscriptSearch.Match?,
                     verifySession: Bool = false) -> PincerRoute.Resolution {
        let resolution = route.resolve(in: self.gateways, verifySession: verifySession, preferring: self.selectedGatewayId)
        if case let .openChat(target, _) = resolution {
            self.findRequest = FindRequest(target: target, query: query, match: match)
        }
        return self.open(route, verifySession: verifySession)
    }

    /// Follows a `pincer://` link. Nil (and nothing happens) when it isn't one Pincer understands.
    @discardableResult
    public func open(url: URL) -> PincerRoute.Resolution? {
        guard let route = PincerRoute.parse(url) else {
            // The browser coming back from an MCP OAuth sign-in: just refresh the servers.
            if MCPServers.isReturnURL(url) {
                self.selectedGateway?.mcp.handleOAuthReturn()
                return nil
            }
            if url.scheme?.lowercased() == PincerRoute.scheme {
                self.routeNotice = RouteNotice(PincerRoute.Notice.invalidLink)
            }
            return nil
        }
        return self.open(route)
    }

    /// The route to a chat, written so it works on other devices (the demo by name, not id).
    public func route(for target: Notifier.Target, messageId: String? = nil) -> PincerRoute {
        let store = self.gateways.first { $0.id == target.gatewayId }
        return PincerRoute(target: target, isDemo: store?.profile.isDemo ?? false, messageId: messageId,
                           gatewayURL: store?.profile.url, gatewayHost: store?.gatewayHost)
    }

    /// The pending jump for `target`, once: it's cleared when taken.
    public func takeMessageJump(for target: Notifier.Target) -> MessageJump? {
        guard let jump = self.messageJump, jump.target == target else { return nil }
        self.messageJump = nil
        return jump
    }
}
