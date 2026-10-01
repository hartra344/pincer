#if os(macOS) || os(iOS)
import SwiftUI
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Device settings row must only display identity already owned by AppModel.
@MainActor
@Suite("Settings device identity", .serialized)
struct SettingsDeviceIdentityTests {
    @Test func renderingDeviceSectionDoesNotCreateIdentity() {
        guard Keychain.isInMemory else {
            Issue.record("the hosted settings identity test must use the in-memory Keychain")
            return
        }

        Keychain.withIsolatedMemoryStore {
            let scratch = ScratchDefaults()
            defer { scratch.remove() }
            let app = AppModel(defaults: scratch.defaults)
            let form = SettingsForm(sections: [.device])
                .environment(app)
            #if os(macOS)
            let root = form.frame(width: 520)
            let host = NSHostingView(rootView: root)
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            #else
            let host = UIHostingController(rootView: form)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.loadViewIfNeeded()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            #endif

            #expect(Keychain.isolatedDeviceIdentityReadCount == 0,
                    "evaluating the Device settings section must not read the Keychain identity")
            #expect(!Keychain.isolatedDeviceIdentityIsStored,
                    "rendering with no identity must not create one")
            #expect(Keychain.realKeychainCalls == 0)

            let gateway = app.add(.demo(), secret: nil)
            let readsAfterFirstGateway = Keychain.isolatedDeviceIdentityReadCount
            #expect(app.deviceIdForDisplay == gateway.deviceId)
            #if os(macOS)
            host.rootView = root
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            #else
            host.rootView = form
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            #endif
            #expect(Keychain.isolatedDeviceIdentityReadCount == readsAfterFirstGateway,
                    "refreshing the Settings row displays the cached ID without another Keychain read")
            #expect(Keychain.isolatedDeviceIdentityIsStored)
        }
    }
}
#endif
