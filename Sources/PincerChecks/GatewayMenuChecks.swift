import Foundation
@testable import PincerKit

/// Offline: the Gateway switcher's model rules.
@MainActor
func runGatewayMenuOfflineChecks() {
    typealias Input = GatewayMenuModel.Input
    let home = Input(name: "Home Lab", state: .connected)
    let office = Input(name: "Office", state: .failed("x"))
    let demo = Input(name: "Demo", state: .connected, isDemo: true)

    let single = GatewayMenuModel.build([home], selectedId: home.id)
    check(!single.canCycle && single.next(after: home.id) == nil && single.previous(before: home.id) == nil,
          "gateway menu: one Gateway can't cycle")
    check(single.addAction == .addGateway && !single.showsDemoBadge, "gateway menu: one real Gateway offers Add Gateway")

    let demoOnly = GatewayMenuModel.build([demo], selectedId: demo.id)
    check(demoOnly.showsDemoBadge && demoOnly.addAction == .connectYourGateway
          && demoOnly.selected?.statusText == "Demo", "gateway menu: demo only shows the badge and Connect Your Gateway")

    let mixed = GatewayMenuModel.build([home, office, demo], selectedId: demo.id)
    check(mixed.addAction == .addGateway && mixed.hasDemo, "gateway menu: demo selected with real Gateways adds")
    check(GatewayMenuModel.build([home, demo], selectedId: home.id).addAction == .addGateway
          && !GatewayMenuModel.build([home, demo], selectedId: home.id).showsDemoBadge,
          "gateway menu: real selected adds, no badge")
    check(mixed.entries[1].statusText == "Can't connect" && mixed.entries[1].accessibilityLabel == "Office, can't connect",
          "gateway menu: failed status word and label")
    check(mixed.entries[0].accessibilityLabel == "Home Lab, connected", "gateway menu: accessibility label")
    check(mixed.next(after: demo.id) == home.id && mixed.previous(before: home.id) == demo.id
          && mixed.next(after: home.id) == office.id, "gateway menu: next/previous wrap in saved order")
    let long = String(repeating: "Long Name ", count: 12)
    let longInput = Input(name: long, state: .connected)
    check(GatewayMenuModel.build([longInput], selectedId: longInput.id).selected?.name == long,
          "gateway menu: long names kept intact")
    check(ShortcutCommand.nextGateway.defaultCombo == nil && ShortcutCommand.previousGateway.defaultCombo == nil
          && ShortcutCommand.listed(in: .chat).contains(.nextGateway), "gateway menu: shortcuts unassigned in Chat")
}

/// Demo: the switcher over a real `AppModel` with the demo and a second (unstarted) Gateway.
@MainActor
func runDemoGatewayMenuChecks() {
    let (defaults, suite) = scratchDefaults()
    let real = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
    GatewayProfileStore.save([real], to: defaults)
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    app.openDemo()
    guard let demo = app.demoGateway else { return check(false, "gateway menu: demo added") }
    check(app.gatewayMenu.showsDemoBadge && app.gatewayMenu.hasDemo && app.gatewayMenu.addAction == .addGateway,
          "gateway menu: demo selected beside Home shows the badge and Add Gateway")
    check(app.gatewayMenu.entries.count == 2 && app.gatewayMenu.canCycle, "gateway menu: demo and Home listed")
    // The switcher's Gateway Settings / Automations / Setup Assistant / Reconnect section needs a selection.
    check(app.selectedGateway?.id == demo.id, "gateway menu: the demo is selected, so its Gateway actions show")

    app.selectNextGateway()
    check(app.selectedGatewayId != demo.id && app.selectedGatewayId != nil, "gateway menu: next switches away from the demo")
    check(!app.gatewayMenu.showsDemoBadge && app.gatewayMenu.addAction == .addGateway,
          "gateway menu: real selected drops the badge")
    app.selectNextGateway()
    check(app.selectedGatewayId == demo.id, "gateway menu: next wraps back to the demo")
    app.selectPreviousGateway()
    app.selectPreviousGateway()
    check(app.selectedGatewayId == demo.id, "gateway menu: previous wraps")

    app.leaveDemo()
    check(!app.gatewayMenu.hasDemo, "gateway menu: leaving the demo clears hasDemo")
    check(!app.gatewayMenu.entries.contains { $0.isDemo } && app.gatewayMenu.entries.count == 1,
          "gateway menu: leaving the demo removes its entry")
    let before = app.selectedGatewayId
    app.selectNextGateway()
    check(app.selectedGatewayId == before, "gateway menu: next is a no-op with one Gateway")
}
