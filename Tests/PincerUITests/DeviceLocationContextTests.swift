import Foundation
import Testing
@testable import PincerKit
@testable import PincerUI
#if os(macOS)
import AppKit
import SwiftUI
#endif

/// Verifies stale Core Location callbacks by object identity without creating a location manager.
@Suite("Device location callback routing")
struct DeviceLocationContextTests {
    @Test func oldManagerCannotBorrowTheReplacementRequestGeneration() {
        let oldManager = NSObject()
        let currentManager = NSObject()
        let currentRequest = LocationRequestToken(manager: ObjectIdentifier(currentManager), generation: 2)

        #expect(currentRequest.generation(for: ObjectIdentifier(currentManager)) == 2)
        #expect(currentRequest.generation(for: ObjectIdentifier(oldManager)) == nil,
                "a late callback from the stopped manager cannot be routed to the current generation")
    }
}

#if os(macOS)
/// Hosts the real settings section without configuring a platform location driver or prompting.
@MainActor
@Suite("Location settings section", .serialized)
struct LocationSettingsSectionTests {
    @Test func optInRendersAdditionalStatusWithoutRequestingPermission() {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let app = AppModel(defaults: scratch.defaults)

        #expect(!app.locationContext.enabled)
        let offHeight = Self.height(app: app)

        app.locationContext.setEnabled(true)
        let onHeight = Self.height(app: app)

        #expect(app.locationContext.enabled)
        #expect(onHeight > offHeight, "the opted-in settings state includes its status row")
    }

    private static func height(app: AppModel) -> CGFloat {
        let host = NSHostingView(rootView: Form { LocationSettingsSection() }
            .environment(app)
            .frame(width: 520))
        host.layout()
        return host.fittingSize.height
    }
}
#endif
