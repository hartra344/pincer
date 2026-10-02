import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Cold-launch routes")
struct ColdLaunchRouteTests {
    @Test func unknownSenderRouteWaitsForSavedGatewayToLoad() {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([profile], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        let route = PincerRoute(
            gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .unknownGateway)
        #expect(app.routeNotice == nil, "a cold-launch Gateway may list the only matching chat shortly")
        #expect(app.gatewayListRequests == 0, "don't present the final unknown-Gateway state while stores are loading")
    }

    @Test func knownLocalGatewayRouteOpensWithoutWaitingForItsSessionList() {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([profile], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        let route = PincerRoute(
            gateway: .id(profile.id), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .openChat(
            Notifier.Target(gatewayId: profile.id, sessionKey: "agent:main:discord:channel:123"), messageId: nil))
        #expect(app.selectedGatewayId == profile.id)
        #expect(app.routeNotice == nil)
    }

    @Test func coldRouteOpensOnceSavedGatewayListsItsMatchingChat() {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([profile], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123",
                                messageId: "message-1")
        #expect(app.open(route) == .unknownGateway)
        #expect(app.routeNotice == nil)
        #expect(app.pendingExternalRoute == route)

        app.gateways[0].applySnapshot(Fixtures.json("""
        {"sessions":[{"key":"agent:main:discord:channel:123"}]}
        """))

        #expect(app.selectedGatewayId == profile.id)
        #expect(app.messageJump?.messageId == "message-1")
        #expect(app.routeNotice == nil)
        #expect(app.pendingExternalRoute == nil)
    }

    @Test func provisionalHolderWaitsForEveryColdGatewayBeforeChoosing() {
        let scratch = ScratchDefaults()
        let profiles = [
            GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none),
            GatewayProfile(name: "Office", url: "ws://127.0.0.1:2", authMode: .none),
        ]
        GatewayProfileStore.save(profiles, to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .unknownGateway)
        app.gateways[0].applySnapshot(Fixtures.json("""
        {"sessions":[{"key":"agent:main:discord:channel:123"}]}
        """))
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
        let scratch = ScratchDefaults()
        let profiles = [
            GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none),
            GatewayProfile(name: "Office", url: "ws://127.0.0.1:2", authMode: .none),
        ]
        GatewayProfileStore.save(profiles, to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }
        app.gateways[0].applySnapshot(Fixtures.json("""
        {"sessions":[{"key":"agent:main:discord:channel:123"}]}
        """))

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .openChat(
            Notifier.Target(gatewayId: profiles[0].id, sessionKey: "agent:main:discord:channel:123"), messageId: nil))
        #expect(app.pendingExternalRoute == nil)
        #expect(app.selectedGatewayId == profiles[0].id)
    }

    @Test func partialSessionEventsBeforeFirstListDoNotResolveAColdRoute() throws {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([profile], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        let key = "agent:main:discord:channel:123"
        let row = try #require(SessionRow(Fixtures.json(#"{"key":"\#(key)"}"#)))
        app.gateways[0].setSession(row, for: key)
        let route = PincerRoute(gateway: .id(UUID()), sessionKey: key)
        #expect(route.resolve(in: app.gateways) == .unknownGateway)
    }

    @Test func unknownRouteResolvesWhenSavedGatewayListIsSuccessfullyEmpty() {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([profile], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")
        #expect(app.open(route) == .unknownGateway)
        app.gateways[0].applySnapshot(Fixtures.json(#"{"sessions":[]}"#))
        #expect(app.pendingExternalRoute == nil)
        #expect(app.routeNotice?.message == PincerRoute.Notice.unknownGateway)
        #expect(app.gatewayListRequests == 1)
    }

    @Test func zeroDeadlineShowsUnknownOnlyAfterFinalResolution() async {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([profile], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        app.pendingExternalRouteTimeout = .zero
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        #expect(app.open(PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:123")) == .unknownGateway)
        #expect(app.routeNotice == nil)
        await app.waitForPendingExternalRouteResolution()
        #expect(app.pendingExternalRoute == nil)
        #expect(app.routeNotice?.message == PincerRoute.Notice.unknownGateway)
        #expect(app.gatewayListRequests == 1)
    }

    @Test func directChatOpenCancelsOlderPendingRouteAndLaterSnapshotCannotStealFocus() {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([profile], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        _ = app.open(PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:old",
                                 messageId: "old-message"))
        app.open(Notifier.Target(gatewayId: profile.id, sessionKey: "agent:main:main"))
        app.gateways[0].applySnapshot(Fixtures.json(#"{"sessions":[{"key":"agent:main:discord:channel:old"}]}"#))
        #expect(app.pendingExternalRoute == nil)
        #expect(app.selectedGatewayId == profile.id)
        #expect(app.gateways[0].selectedKey == "agent:main:main")
        #expect(app.messageJump == nil)
        #expect(app.routeNotice == nil)
    }

    @Test func gatewaySelectionCancelsPendingRouteAndLaterSnapshotCannotStealFocus() {
        let scratch = ScratchDefaults()
        let profiles = [
            GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none),
            GatewayProfile(name: "Office", url: "ws://127.0.0.1:2", authMode: .none),
        ]
        GatewayProfileStore.save(profiles, to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        _ = app.open(PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:old",
                                 messageId: "old-message"))
        app.selectedGatewayId = profiles[1].id
        app.gateways[0].applySnapshot(Fixtures.json(#"{"sessions":[{"key":"agent:main:discord:channel:old"}]}"#))
        #expect(app.pendingExternalRoute == nil)
        #expect(app.selectedGatewayId == profiles[1].id)
        #expect(app.messageJump == nil)
        #expect(app.routeNotice == nil)
    }

    @Test func automaticSessionSelectionDoesNotCancelPendingExternalRoute() {
        let scratch = ScratchDefaults()
        let profile = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([profile], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            app.gateways.forEach { $0.stop() }
            scratch.remove()
        }

        let route = PincerRoute(gateway: .id(UUID()), sessionKey: "agent:main:discord:channel:old")
        _ = app.open(route)
        // Bootstrap and other automatic selection updates only set the store's selected key.
        app.gateways[0].selectedKey = "agent:main:main"
        #expect(app.pendingExternalRoute == route)
        #expect(app.routeNotice == nil)
    }
}
