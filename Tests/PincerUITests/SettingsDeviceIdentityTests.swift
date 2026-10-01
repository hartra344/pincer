#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI

/// The Device settings row must only display identity already owned by AppModel.
@MainActor
@Suite("Settings device identity", .serialized)
struct SettingsDeviceIdentityTests {
    @Test func renderingDeviceSectionDoesNotCreateIdentity() {
        guard Keychain.isInMemory else {
            Issue.record("the hosted settings identity test must use the in-memory Keychain")
            return
        }

        // This process-local test entry is safe to clear; never touch a user's Keychain item.
        Keychain.delete(DeviceIdentity.keychainAccount)
        defer { Keychain.delete(DeviceIdentity.keychainAccount) }
        #expect(DeviceIdentity.loadExisting() == nil)

        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)
        let host = NSHostingView(rootView: SettingsForm(sections: [.device])
            .environment(app)
            .frame(width: 520))
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize

        #expect(DeviceIdentity.loadExisting() == nil,
                "evaluating the Device settings section must not create a Keychain identity")
        #expect(Keychain.realKeychainCalls == 0)
    }
}
#endif
