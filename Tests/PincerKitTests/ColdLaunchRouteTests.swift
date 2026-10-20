import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Cold-launch routes")
struct ColdLaunchRouteTests {
    /// An app model over `count` saved (never-connected) gateways.
    func launch(gateways count: Int = 1) -> (app: AppModel, scratch: ScratchDefaults, profiles: [GatewayProfile]) {
        let scratch = ScratchDefaults()
        let profiles = [
            GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none),
            GatewayProfile(name: "Office", url: "ws://127.0.0.1:2", authMode: .none),
        ].prefix(count).map { $0 }
        GatewayProfileStore.save(profiles, to: scratch.defaults)
        return (AppModel(defaults: scratch.defaults), scratch, profiles)
    }

    func shutDown(_ app: AppModel, _ scratch: ScratchDefaults) {
        app.gateways.forEach { $0.stop() }
        scratch.remove()
    }

    /// Delivers a session list holding only `key` to `gateway`.
    func list(_ key: String, on gateway: GatewayStore) {
        gateway.applySnapshot(Fixtures.json(#"{"sessions":[{"key":"\#(key)"}]}"#))
    }

    @Test func unknownSenderRouteWaitsForSavedGatewayToLoad() {
        let (app, scratch, _) = self.launch()
        defer { self.shutDown(app, scratch) }

        let route = PincerRoute(
            gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .unknownGateway)
        #expect(app.routeNotice == nil, "a cold-launch Gateway may list the only matching chat shortly")
        #expect(app.gatewayListRequests == 0, "don't present the final unknown-Gateway state while stores are loading")
    }

    @Test func knownLocalGatewayRouteOpensWithoutWaitingForItsSessionList() {
        let (app, scratch, profiles) = self.launch()
        let profile = profiles[0]
        defer { self.shutDown(app, scratch) }

        let route = PincerRoute(
            gateway: .id(profile.id), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .openChat(
            Notifier.Target(gatewayId: profile.id, sessionKey: "agent:main:discord:channel:123"), messageId: nil))
        #expect(app.selectedGatewayId == profile.id)
        #expect(app.routeNotice == nil)
    }

    @Test func coldRouteOpensOnceSavedGatewayListsItsMatchingChat() {
        let (app, scratch, profiles) = self.launch()
        let profile = profiles[0]
        defer { self.shutDown(app, scratch) }

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123",
                                messageId: "message-1")
        #expect(app.open(route) == .unknownGateway)
        #expect(app.routeNotice == nil)
        #expect(app.pendingExternalRoute == route)

        self.list("agent:main:discord:channel:123", on: app.gateways[0])

        #expect(app.selectedGatewayId == profile.id)
        #expect(app.messageJump?.messageId == "message-1")
        #expect(app.routeNotice == nil)
        #expect(app.pendingExternalRoute == nil)
    }

    @Test func provisionalHolderWaitsForEveryColdGatewayBeforeChoosing() {
        let (app, scratch, profiles) = self.launch(gateways: 2)
        defer { self.shutDown(app, scratch) }

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .unknownGateway)
        self.list("agent:main:discord:channel:123", on: app.gateways[0])
        #expect(app.pendingExternalRoute == route)
        #expect(app.openRequests == 0)

        // A successfully empty session list is ready too; after it arrives the first store is the
        // only holder and the pending link can be applied.
        app.gateways[1].applySnapshot(Fixtures.json(#"{"sessions":[]}"#))
        #expect(app.pendingExternalRoute == nil)
        #expect(app.selectedGatewayId == profiles[0].id)
        #expect(app.openRequests == 1)
    }

    @Test func knownCachedUniqueHolderOpensImmediatelyWhileAnotherGatewayIsCold() {
        let (app, scratch, profiles) = self.launch(gateways: 2)
        defer { self.shutDown(app, scratch) }
        self.list("agent:main:discord:channel:123", on: app.gateways[0])

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .openChat(
            Notifier.Target(gatewayId: profiles[0].id, sessionKey: "agent:main:discord:channel:123"), messageId: nil))
        #expect(app.pendingExternalRoute == nil)
        #expect(app.selectedGatewayId == profiles[0].id)
    }

    @Test func partialSessionEventsBeforeFirstListDoNotResolveAColdRoute() throws {
        let (app, scratch, _) = self.launch()
        defer { self.shutDown(app, scratch) }

        let key = "agent:main:discord:channel:123"
        let row = try #require(SessionRow(Fixtures.json(#"{"key":"\#(key)"}"#)))
        app.gateways[0].setSession(row, for: key)
        let route = PincerRoute(gateway: .id(UUID()), sessionKey: key)
        #expect(route.resolve(in: app.gateways) == .unknownGateway)
    }

    @Test func unknownRouteResolvesWhenSavedGatewayListIsSuccessfullyEmpty() {
        let (app, scratch, _) = self.launch()
        defer { self.shutDown(app, scratch) }

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .unknownGateway)
        app.gateways[0].applySnapshot(Fixtures.json(#"{"sessions":[]}"#))
        #expect(app.pendingExternalRoute == nil)
        #expect(app.routeNotice?.message == PincerRoute.Notice.unknownGateway)
        #expect(app.gatewayListRequests == 1)
    }

    @Test func zeroDeadlineShowsUnknownOnlyAfterFinalResolution() async {
        let (app, scratch, _) = self.launch()
        app.pendingExternalRouteTimeout = .zero
        defer { self.shutDown(app, scratch) }

        #expect(app.open(PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")) == .unknownGateway)
        #expect(app.routeNotice == nil)
        await app.waitForPendingExternalRouteResolution()
        #expect(app.pendingExternalRoute == nil)
        #expect(app.routeNotice?.message == PincerRoute.Notice.unknownGateway)
        #expect(app.gatewayListRequests == 1)
    }

    @Test func directChatOpenCancelsOlderPendingRouteAndLaterSnapshotCannotStealFocus() {
        let (app, scratch, profiles) = self.launch()
        let profile = profiles[0]
        defer { self.shutDown(app, scratch) }

        _ = app.open(PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:old",
                                 messageId: "old-message"))
        app.open(Notifier.Target(gatewayId: profile.id, sessionKey: "agent:main:main"))
        self.list("agent:main:discord:channel:old", on: app.gateways[0])
        #expect(app.pendingExternalRoute == nil)
        #expect(app.selectedGatewayId == profile.id)
        #expect(app.gateways[0].selectedKey == "agent:main:main")
        #expect(app.messageJump == nil)
        #expect(app.routeNotice == nil)
    }

    @Test func gatewaySelectionCancelsPendingRouteAndLaterSnapshotCannotStealFocus() {
        let (app, scratch, profiles) = self.launch(gateways: 2)
        defer { self.shutDown(app, scratch) }

        _ = app.open(PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:old",
                                 messageId: "old-message"))
        app.selectedGatewayId = profiles[1].id
        self.list("agent:main:discord:channel:old", on: app.gateways[0])
        #expect(app.pendingExternalRoute == nil)
        #expect(app.selectedGatewayId == profiles[1].id)
        #expect(app.messageJump == nil)
        #expect(app.routeNotice == nil)
    }

    @Test func automaticSessionSelectionDoesNotCancelPendingExternalRoute() {
        let (app, scratch, _) = self.launch()
        defer { self.shutDown(app, scratch) }

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:old")
        _ = app.open(route)
        // Bootstrap and other automatic selection updates only set the store's selected key.
        app.gateways[0].selectedKey = "agent:main:main"
        #expect(app.pendingExternalRoute == route)
        #expect(app.routeNotice == nil)
    }
}
