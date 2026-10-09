import Foundation
import Testing
@testable import PincerKit

/// #955: once a real Gateway connects, Pincer offers to remove the demo, and only once.
@MainActor
@Suite("Demo removal offer")
struct DemoRemovalOfferTests {
    @Test func quietWithoutTheDemoOrAConnectedGateway() {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer {
            for gateway in app.gateways { app.remove(gateway.id) }
            scratch.remove()
        }
        #expect(app.demoRemovalOffer == nil)
        app.openDemo()
        _ = app.add(GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none), secret: nil)
        // Home never connects (nothing listens on port 1), so there's nothing to offer yet.
        #expect(app.demoRemovalOffer == nil)
        #expect(!app.demoRemovalOffered)
    }

    /// Picking the demo while a real Gateway is already saved is deliberate: it's never offered for
    /// removal, or Try the Demo would be met with "Remove the Demo?".
    @Test func openingTheDemoBesideARealGatewayNeverOffers() {
        let scratch = ScratchDefaults()
        let real = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([real], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            for gateway in app.gateways { app.remove(gateway.id) }
            scratch.remove()
        }
        app.openDemo()
        #expect(app.demoGateway != nil)
        #expect(app.demoRemovalOffered)
        #expect(app.demoRemovalOffer == nil)
    }

    @Test func removingAnswersAndRemovesTheDemo() {
        let scratch = ScratchDefaults()
        let real = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([real], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            for gateway in app.gateways { app.remove(gateway.id) }
            scratch.remove()
        }
        app.openDemo()
        app.answerDemoRemovalOffer(remove: true)
        #expect(app.demoGateway == nil)
        #expect(app.gateways.map(\.id) == [real.id])
        #expect(app.demoRemovalOffered)
        #expect(AppModel(defaults: scratch.defaults).demoRemovalOffered)
    }

    @Test func keepingIsRememberedAndNeverAskedAgain() {
        let scratch = ScratchDefaults()
        let app = AppModel(defaults: scratch.defaults)
        defer {
            for gateway in app.gateways { app.remove(gateway.id) }
            scratch.remove()
        }
        app.openDemo()
        app.answerDemoRemovalOffer(remove: false)
        #expect(app.demoGateway != nil)
        #expect(app.demoRemovalOffer == nil)
        #expect(scratch.defaults.bool(forKey: AppModel.demoRemovalOfferedKey))
    }
}
