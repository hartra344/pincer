import Foundation
import Testing
@testable import PincerKit

@MainActor
@Suite("Leave demo")
struct LeaveDemoTests {
    private func makeApp(real: [GatewayProfile], _ scratch: ScratchDefaults) -> AppModel {
        if !real.isEmpty { GatewayProfileStore.save(real, to: scratch.defaults) }
        return AppModel(defaults: scratch.defaults)
    }

    private func cleanUp(_ app: AppModel, _ scratch: ScratchDefaults) {
        for gateway in app.gateways { app.remove(gateway.id) }
        scratch.remove()
    }

    @Test func removesTheDemoAndKeepsRealGateways() {
        let scratch = ScratchDefaults()
        let real = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        let app = self.makeApp(real: [real], scratch)
        defer { self.cleanUp(app, scratch) }

        app.openDemo()
        #expect(app.demoGateway != nil)
        #expect(app.selectedGatewayId == app.demoGateway?.id)

        app.leaveDemo()
        #expect(app.demoGateway == nil)
        #expect(app.gateways.map(\.id) == [real.id])
        #expect(app.gateways.first?.profile.name == "Home")
        #expect(app.gateways.first?.profile.url == "ws://127.0.0.1:1")
        #expect(app.selectedGatewayId == real.id)
        #expect(app.firstRun.presentation == nil)
        #expect(GatewayProfileStore.load(from: scratch.defaults).map(\.id) == [real.id])
    }

    @Test func connectOpensFindOverTheChatListWhenGatewaysRemain() {
        let scratch = ScratchDefaults()
        let real = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
        let app = self.makeApp(real: [real], scratch)
        defer { self.cleanUp(app, scratch) }

        app.openDemo()
        app.leaveDemo(connect: true)
        #expect(app.firstRun.presentation == .sheet)
        #expect(app.firstRun.state.step == .findGateway)
    }

    @Test func connectSkipsWelcomeWhenNothingRemains() {
        let scratch = ScratchDefaults()
        let app = self.makeApp(real: [], scratch)
        defer { self.cleanUp(app, scratch) }

        app.openDemo()
        app.leaveDemo(connect: true)
        #expect(app.gateways.isEmpty)
        #expect(app.selectedGatewayId == nil)
        #expect(app.firstRun.presentation == .window)
        #expect(app.firstRun.state.step == .haveGateway)
    }

    @Test func leavingWithoutConnectShowsWelcomeWhenNothingRemains() {
        let scratch = ScratchDefaults()
        let app = self.makeApp(real: [], scratch)
        defer { self.cleanUp(app, scratch) }

        app.openDemo()
        app.leaveDemo()
        #expect(app.firstRun.presentation == .window)
        #expect(app.firstRun.state.step == .welcome)
    }

    @Test func leavingWithoutADemoChangesNothing() {
        let scratch = ScratchDefaults()
        let a = GatewayProfile(name: "A", url: "ws://127.0.0.1:1", authMode: .none)
        let b = GatewayProfile(name: "B", url: "ws://127.0.0.1:2", authMode: .none)
        let app = self.makeApp(real: [a, b], scratch)
        defer { self.cleanUp(app, scratch) }

        app.selectedGatewayId = b.id
        app.leaveDemo()
        #expect(app.gateways.map(\.id) == [a.id, b.id])
        #expect(app.selectedGatewayId == b.id)
    }

    @Test func reenteringGivesAFreshDemo() {
        let scratch = ScratchDefaults()
        let app = self.makeApp(real: [], scratch)
        defer { self.cleanUp(app, scratch) }

        app.openDemo()
        let first = app.demoGateway?.id
        app.leaveDemo()
        app.openDemo()
        #expect(app.demoGateway != nil)
        #expect(app.demoGateway?.id != first)
        #expect(app.gateways.count == 1)
    }
}
