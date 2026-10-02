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
}
