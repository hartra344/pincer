import Foundation
import Testing
@testable import PincerKit

/// #955: once a real Gateway connects, Pincer offers to remove the demo, and only once.
@MainActor
@Suite("Demo removal offer")
struct DemoRemovalOfferTests {
    @Test func quietWithoutTheDemoOrAConnectedGateway() {
        let scratch = ScratchDefaults()
        let real = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        GatewayProfileStore.save([real], to: scratch.defaults)
        let app = AppModel(defaults: scratch.defaults)
        defer {
            for gateway in app.gateways { app.remove(gateway.id) }
            scratch.remove()
        }
        #expect(app.demoRemovalOffer == nil)
        app.openDemo()
        // Home never connects (nothing listens on port 1), so there's nothing to offer yet.
        #expect(app.demoRemovalOffer == nil)
        #expect(!app.demoRemovalOffered)
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
