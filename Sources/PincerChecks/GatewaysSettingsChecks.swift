import Foundation
@testable import PincerKit

/// Offline (#955): Settings ▸ Gateways holds every connection, opens at a given Gateway, and the
/// demo-removal offer stays quiet until a real Gateway connects, then is asked once.
@MainActor
func runGatewaysSettingsOfflineChecks() {
    for platform in AppSettingsPlatform.allCases {
        check(AppSettingsPage.pages(on: platform).contains(.gateways)
              && AppSettingsPage.gateways.sections(on: platform) == [.gateways, .device]
              && !AppSettingsPage.general.sections(on: platform).contains(.device),
              "gateways settings: \(platform) has a Gateways page with This device")
    }
    let id = UUID()
    let route = AppSettingsRoute(page: .chats, gatewayId: id)
    check(route.page == .gateways && route.gatewayId == id, "gateways settings: a Gateway route opens Gateways")

    let (defaults, suite) = scratchDefaults()
    let home = GatewayProfile(name: "Home", url: "ws://127.0.0.1:1", authMode: .none)
    let work = GatewayProfile(name: "Work", url: "ws://127.0.0.1:2", authMode: .none)
    GatewayProfileStore.save([home, work], to: defaults)
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    app.pendingAppSettingsGatewayId = work.id
    check(app.takePendingAppSettingsGatewayId() == work.id && app.takePendingAppSettingsGatewayId() == nil,
          "gateways settings: the pending Gateway is taken once")
    app.selectedGatewayId = work.id
    check(app.gatewayForSettings(nil)?.id == work.id && app.gatewayForSettings(home.id)?.id == home.id
          && app.gatewayForSettings(UUID())?.id == work.id, "gateways settings: edits the picked, else the selected Gateway")

    // Edit and remove go through the same AppModel calls the page makes.
    let edited = GatewayProfile(id: home.id, name: "Home Lab", url: "ws://127.0.0.1:3", authMode: .none)
    app.update(edited, secret: nil, credentialsChanged: true)
    check(app.gateways.first { $0.id == home.id }?.profile.url == "ws://127.0.0.1:3"
          && GatewayProfileStore.load(from: defaults).first { $0.id == home.id }?.name == "Home Lab",
          "gateways settings: Apply saves the connection")
    app.remove(home.id)
    check(app.gateways.map(\.id) == [work.id], "gateways settings: Remove from Pincer removes only that Gateway")

    app.openDemo()
    check(app.demoRemovalOffer == nil, "gateways settings: no demo offer before a real Gateway connects")
    app.answerDemoRemovalOffer(remove: false)
    check(app.demoGateway != nil && app.demoRemovalOffered && defaults.bool(forKey: AppModel.demoRemovalOfferedKey),
          "gateways settings: keeping the demo is remembered")
}

/// Live (#955): with the demo added, a real Gateway's first connection offers once to remove it.
@MainActor
func runLiveDemoRemovalOfferChecks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    let app = AppModel(defaults: defaults)
    defer {
        for gateway in app.gateways { app.remove(gateway.id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    app.openDemo()
    check(app.demoRemovalOffer == nil, "demo offer: none with only the demo")
    let gateway = app.add(GatewayProfile(name: "Mock", url: url, authMode: .token), secret: token)
    let offered = await waitFor("demo removal offer", timeout: 25) { app.demoRemovalOffer?.id == gateway.id }
    check(offered, "demo offer: a real Gateway connecting offers to remove the demo")
    guard offered else { return }
    app.answerDemoRemovalOffer(remove: true)
    check(app.demoGateway == nil && app.gateways.map(\.id) == [gateway.id], "demo offer: Remove Demo keeps the real Gateway")
    check(app.demoRemovalOffer == nil, "demo offer: answered")
    app.openDemo()
    check(app.demoGateway != nil && app.demoRemovalOffer == nil, "demo offer: never asked twice")
    let reloaded = AppModel(defaults: defaults)
    check(reloaded.demoRemovalOffered, "demo offer: the answer survives relaunch")
}
