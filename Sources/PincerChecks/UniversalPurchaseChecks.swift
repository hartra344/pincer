import Foundation
import PincerKit

/// The iOS app ships as the iOS platform of the Mac app's App Store record (universal purchase,
/// #1065), and a fresh install under the new bundle ID still finds the gateways the old one saved.
@MainActor
func runUniversalPurchaseChecks() {
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let project = try? String(contentsOf: root.appending(path: "project.yml"), encoding: .utf8),
          let script = try? String(contentsOf: root.appending(path: "scripts/testflight.sh"), encoding: .utf8),
          let appStore = try? String(contentsOf: root.appending(path: "project.appstore.yml"), encoding: .utf8)
    else {
        check(false, "universal purchase: project.yml, project.appstore.yml and scripts/testflight.sh are readable from \(root.path)")
        return
    }
    let ids = ReleaseIdentity.bundleIdentifiers(projectYAML: project)
    check(ids["Pincer-iOS"] == "chat.pincer.mac" && ids["Pincer-macOS"] == "chat.pincer.mac",
          "universal purchase: iOS and macOS apps share chat.pincer.mac (\(ids["Pincer-iOS"] ?? "-"), \(ids["Pincer-macOS"] ?? "-"))")
    check(ids["PincerShare-iOS"] == "chat.pincer.mac.share" && ids["PincerShare-macOS"] == "chat.pincer.mac.share",
          "universal purchase: both Share extensions are chat.pincer.mac.share")
    check(ids["PincerNotifications-iOS"] == "chat.pincer.mac.notifications",
          "universal purchase: the notification service is chat.pincer.mac.notifications")
    check(!ids.values.contains { $0.hasPrefix("chat.pincer.ios") }, "universal purchase: no target still uses chat.pincer.ios (\(ids))")

    let testFlight = ReleaseIdentity.testFlightBundleIdentifiers(script: script)
    check(testFlight.apps == ["ios": "chat.pincer.mac", "macos": "chat.pincer.mac"],
          "universal purchase: TestFlight uploads both platforms to chat.pincer.mac (\(testFlight.apps))")
    check(testFlight.extraProfileKeys == ["chat.pincer.mac.notifications"],
          "universal purchase: TestFlight signs the notification service as chat.pincer.mac.notifications")
    let profiles = ReleaseIdentity.targetSettings(projectYAML: appStore, key: "PROVISIONING_PROFILE_SPECIFIER")
    check(profiles["Pincer-iOS"] == "Pincer_iOS_Universal_AppStore_CI"
          && profiles["PincerShare-iOS"] == "Pincer_iOS_Universal_Share_AppStore_CI"
          && profiles["PincerNotifications-iOS"] == "Pincer_iOS_Universal_Notifications_AppStore_CI"
          && ReleaseIdentity.testFlightVariable("PROFILE", script: script)["ios"] == "Pincer_iOS_Universal_AppStore_CI"
          && ReleaseIdentity.testFlightVariable("SHARE_PROFILE", script: script)["ios"] == "Pincer_iOS_Universal_Share_AppStore_CI"
          && script.contains("<string>Pincer_iOS_Universal_Notifications_AppStore_CI</string>"),
          "universal purchase: iOS signs with the Pincer_iOS_Universal_* profiles (\(profiles))")

    check(PushRegistrar.topic(bundleIdentifier: nil) == "chat.pincer.mac"
          && PushRegistrar.topic(bundleIdentifier: "") == "chat.pincer.mac"
          && PushRegistrar.topic(bundleIdentifier: "chat.pincer.mac.dev-x") == "chat.pincer.mac.dev-x",
          "universal purchase: the push relay topic is the running bundle ID, falling back to chat.pincer.mac")

    // A fresh chat.pincer.mac install has empty per-app defaults but the same App Group.
    let sharedName = "pincer.checks.universal.shared.\(UUID())", freshName = "pincer.checks.universal.fresh.\(UUID())"
    let shared = UserDefaults(suiteName: sharedName)!, fresh = UserDefaults(suiteName: freshName)!
    defer {
        UserDefaults.standard.removePersistentDomain(forName: sharedName)
        UserDefaults.standard.removePersistentDomain(forName: freshName)
    }
    let home = GatewayProfile(name: "Home", url: "wss://home.tail1234.ts.net", authMode: .token)
    GatewayProfileStore.save([home], to: shared)
    check(GatewayProfileStore.load(from: shared, legacy: fresh).map(\.id) == [home.id],
          "universal purchase: a new install reads gateways the chat.pincer.ios build saved in the App Group")
    check(fresh.data(forKey: "pincer.gatewayProfiles.v1") == nil, "universal purchase: nothing is copied back into per-app defaults")
}
