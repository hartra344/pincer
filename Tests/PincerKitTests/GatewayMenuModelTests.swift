import Foundation
import Testing
@testable import PincerKit

@Suite("Gateway menu model")
struct GatewayMenuModelTests {
    typealias Input = GatewayMenuModel.Input

    private func real(_ name: String, state: ConnectionState = .connected,
                      health: GatewayHealthLevel = .healthy) -> Input
    {
        Input(name: name, state: state, healthLevel: health)
    }

    private func demo(state: ConnectionState = .connected) -> Input {
        Input(name: "Demo", state: state, isDemo: true)
    }

    @Test func oneGatewayCannotCycleAndOffersAddGateway() {
        let home = self.real("Home Lab")
        let menu = GatewayMenuModel.build([home], selectedId: home.id)
        #expect(menu.entries.count == 1)
        #expect(menu.selected?.id == home.id)
        #expect(!menu.canCycle)
        #expect(menu.next(after: home.id) == nil)
        #expect(menu.previous(before: home.id) == nil)
        #expect(menu.addAction == .addGateway)
        #expect(!menu.showsDemoBadge)
        #expect(!menu.hasDemo)
    }

    @Test func demoOnlyShowsBadgeAndConnectAction() {
        let demo = self.demo()
        let menu = GatewayMenuModel.build([demo], selectedId: demo.id)
        #expect(menu.showsDemoBadge)
        #expect(menu.hasDemo)
        #expect(menu.addAction == .connectYourGateway)
        #expect(menu.addActionTitle == "Connect Your Gateway…")
        #expect(menu.selected?.statusText == "Demo")
        #expect(!menu.canCycle)
    }

    @Test func demoStatusIsDemoEvenWhileConnecting() {
        let demo = self.demo(state: .connecting)
        #expect(GatewayMenuModel.build([demo], selectedId: demo.id).selected?.statusText == "Demo")
    }

    @Test func failedDemoShowsTheFailure() {
        let demo = self.demo(state: .failed("boom"))
        #expect(GatewayMenuModel.build([demo], selectedId: demo.id).selected?.statusText == "Can't connect")
    }

    @Test func demoSelectedWithRealGatewayOffersAddGateway() {
        let demo = self.demo()
        let home = self.real("Home Lab")
        let menu = GatewayMenuModel.build([home, demo], selectedId: demo.id)
        #expect(menu.showsDemoBadge)
        #expect(menu.hasDemo)
        #expect(menu.addAction == .addGateway)
        #expect(menu.addActionTitle == "Add Gateway…")
        #expect(menu.canCycle)
    }

    @Test func realSelectedWithDemoPresentAddsGatewayWithoutBadge() {
        let demo = self.demo()
        let home = self.real("Home Lab")
        let menu = GatewayMenuModel.build([home, demo], selectedId: home.id)
        #expect(!menu.showsDemoBadge)
        #expect(menu.hasDemo)
        #expect(menu.addAction == .addGateway)
        #expect(menu.addActionTitle == "Add Gateway…")
        #expect(menu.entries.map(\.isSelected) == [true, false])
    }

    @Test func statusWords() {
        let cases: [(Input, String)] = [
            (self.real("a", state: .failed("x")), "Can't connect"),
            (self.real("a", state: .reconnecting(attempt: 1, delaySeconds: 2, reason: "r")), "Reconnecting…"),
            (self.real("a", state: .connecting), "Connecting…"),
            (self.real("a", state: .idle), "Connecting…"),
            (self.real("a", state: .connected, health: .degraded), "Degraded"),
            (self.real("a", state: .connected), "Connected"),
        ]
        for (input, word) in cases {
            let menu = GatewayMenuModel.build([input], selectedId: input.id)
            #expect(menu.entries.first?.statusText == word, "\(input.state)")
        }
    }

    @Test func nextAndPreviousWrapInSavedOrder() {
        let a = self.real("A"), b = self.real("B"), c = self.real("C")
        let menu = GatewayMenuModel.build([a, b, c], selectedId: a.id)
        #expect(menu.next(after: a.id) == b.id)
        #expect(menu.next(after: b.id) == c.id)
        #expect(menu.next(after: c.id) == a.id)
        #expect(menu.previous(before: a.id) == c.id)
        #expect(menu.previous(before: c.id) == b.id)
        #expect(menu.previous(before: b.id) == a.id)
    }

    @Test func noGatewaysCannotCycle() {
        let menu = GatewayMenuModel.build([], selectedId: nil)
        #expect(menu.selected == nil)
        #expect(menu.next(after: nil) == nil)
        #expect(menu.previous(before: nil) == nil)
        #expect(menu.addAction == .addGateway)
    }

    @Test func accessibilityLabels() {
        let home = self.real("Home Lab")
        let down = self.real("Office", state: .failed("x"))
        let demo = self.demo()
        let menu = GatewayMenuModel.build([home, down, demo], selectedId: home.id)
        #expect(menu.entries[0].accessibilityLabel == "Home Lab, connected")
        #expect(menu.entries[1].accessibilityLabel == "Office, can't connect")
        #expect(menu.entries[2].accessibilityLabel == "Demo, demo gateway")
    }

    @Test func menuTitlesMatchTheMenuBarExtra() {
        let home = self.real("Home Lab")
        let demo = self.demo()
        let menu = GatewayMenuModel.build([home, demo], selectedId: home.id)
        #expect(menu.entries[0].menuTitle == "Home Lab — Connected")
        #expect(menu.entries[1].menuTitle == "Demo")
    }

    @Test func longNamesAreKeptIntact() {
        let long = String(repeating: "Very Long Gateway Name ", count: 8)
        let input = self.real(long)
        let menu = GatewayMenuModel.build([input], selectedId: input.id)
        #expect(menu.selected?.name == long)
        #expect(menu.selected?.accessibilityLabel.hasPrefix(long) == true)
    }
}
