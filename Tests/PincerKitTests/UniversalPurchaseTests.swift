import Foundation
import Testing
@testable import PincerKit

/// iOS ships under the Mac app's bundle ID so both are one App Store record (#1065).
@Suite("Universal purchase identity")
struct UniversalPurchaseTests {
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func projectShipsBothPlatformsUnderTheMacBundleID() throws {
        let project = try String(contentsOf: Self.root.appending(path: "project.yml"), encoding: .utf8)
        let ids = ReleaseIdentity.bundleIdentifiers(projectYAML: project)
        #expect(ids["Pincer-iOS"] == "chat.pincer.mac")
        #expect(ids["Pincer-macOS"] == "chat.pincer.mac")
        #expect(ids["PincerShare-iOS"] == "chat.pincer.mac.share")
        #expect(ids["PincerShare-macOS"] == "chat.pincer.mac.share")
        #expect(ids["PincerNotifications-iOS"] == "chat.pincer.mac.notifications")
        #expect(!ids.values.contains { $0.hasPrefix("chat.pincer.ios") })
    }

    @Test func testFlightUploadsBothPlatformsToTheMacBundleID() throws {
        let script = try String(contentsOf: Self.root.appending(path: "scripts/testflight.sh"), encoding: .utf8)
        let ids = ReleaseIdentity.testFlightBundleIdentifiers(script: script)
        #expect(ids.apps == ["ios": "chat.pincer.mac", "macos": "chat.pincer.mac"])
        #expect(ids.extraProfileKeys == ["chat.pincer.mac.notifications"])
        // Profile names are unique per team, so the chat.pincer.mac iOS profiles get new names.
        #expect(ReleaseIdentity.testFlightVariable("PROFILE", script: script)["ios"] == "Pincer_iOS_Universal_AppStore_CI")
        #expect(ReleaseIdentity.testFlightVariable("SHARE_PROFILE", script: script)["ios"] == "Pincer_iOS_Universal_Share_AppStore_CI")
        #expect(script.contains("<string>Pincer_iOS_Universal_Notifications_AppStore_CI</string>"))
    }

    @Test func appStoreSigningUsesTheUniversalIOSProfiles() throws {
        let yaml = try String(contentsOf: Self.root.appending(path: "project.appstore.yml"), encoding: .utf8)
        let profiles = ReleaseIdentity.targetSettings(projectYAML: yaml, key: "PROVISIONING_PROFILE_SPECIFIER")
        #expect(profiles["Pincer-iOS"] == "Pincer_iOS_Universal_AppStore_CI")
        #expect(profiles["PincerShare-iOS"] == "Pincer_iOS_Universal_Share_AppStore_CI")
        #expect(profiles["PincerNotifications-iOS"] == "Pincer_iOS_Universal_Notifications_AppStore_CI")
        #expect(profiles["Pincer-macOS"] == "Pincer_macOS_AppStore_CI")
    }

    @Test func parserKeepsTargetsApartAndStripsTheDevSuffix() {
        let yaml = """
        settings:
          base:
            PRODUCT_BUNDLE_IDENTIFIER: not.a.target
        targets:
          App:
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: chat.pincer.mac$(PINCER_DEV_SUFFIX)
          # comment
          Ext:
            settings:
              base:
                PRODUCT_BUNDLE_IDENTIFIER: chat.pincer.mac$(PINCER_DEV_SUFFIX).share
        schemes:
          Other:
            PRODUCT_BUNDLE_IDENTIFIER: ignored
        """
        #expect(ReleaseIdentity.bundleIdentifiers(projectYAML: yaml) == ["App": "chat.pincer.mac", "Ext": "chat.pincer.mac.share"])
    }

    @Test func pushTopicFallsBackToTheMacBundleID() {
        #expect(PushRegistrar.topic(bundleIdentifier: nil) == "chat.pincer.mac")
        #expect(PushRegistrar.topic(bundleIdentifier: "") == "chat.pincer.mac")
        #expect(PushRegistrar.topic(bundleIdentifier: "chat.pincer.ios") == "chat.pincer.ios")
    }

    @Test func freshInstallReadsGatewaysFromTheAppGroup() {
        let sharedName = "pincer-tests-shared-\(UUID())", freshName = "pincer-tests-fresh-\(UUID())"
        let shared = UserDefaults(suiteName: sharedName)!, fresh = UserDefaults(suiteName: freshName)!
        defer {
            shared.removePersistentDomain(forName: sharedName)
            fresh.removePersistentDomain(forName: freshName)
        }
        let home = GatewayProfile(name: "Home", url: "wss://home.tail1234.ts.net", authMode: .token)
        GatewayProfileStore.save([home], to: shared)
        #expect(GatewayProfileStore.load(from: shared, legacy: fresh).map(\.id) == [home.id])
        #expect(fresh.data(forKey: GatewayProfileStore.key) == nil)
    }

    @Test func keychainCopyIsSkippedOnceTheAppGroupRecordsIt() {
        // The old build records the copy in the App Group, so the new install doesn't redo it.
        #expect(SharedContainer.keychainMigrationKey == "pincer.keychainSharedGroup")
        #expect(SharedContainer.keychainAccounts(for: []) == [DeviceIdentity.keychainAccount])
    }
}
