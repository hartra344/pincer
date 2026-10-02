import PincerKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct LocationSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let model = self.app.locationContext
        let selectedGateway = self.app.selectedGateway ?? self.app.gateways.first
        Section {
            Toggle(L("Share location context with the agent"), isOn: Binding(
                get: { model.enabled }, set: { model.setEnabled($0) }))
            if model.enabled {
                if selectedGateway?.locationContextUnsupported == true {
                    Label(L("This Gateway does not support location context. Messages are still sent without location."),
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("location-context-gateway-unsupported")
                }
                Label(self.status(model.status, accuracy: model.snapshot?.accuracy),
                      systemImage: model.status == .ready ? "location.fill" : "location")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("location-context-status")
                if model.status == .permissionRequired {
                    Button(L("Allow Location")) { model.requestPermission() }
                } else if model.status == .denied || model.status == .restricted {
                    Button(L("Open Location Settings")) { Self.openSettings() }
                } else if model.status == .unavailable {
                    Button(L("Try Again")) { model.refresh() }
                }
            }
        } header: {
            Text("Location", bundle: .module)
        } footer: {
            Text("When enabled, Pincer shares a recent device location as context for the agent, separate from your message text. The Gateway may retain this context in chat history. Reported accuracy comes from the device and may be reduced by system privacy settings. Pincer requests a one-time fix only while the app is active and sends your message without location if no recent fix is available. Commands do not include location. Turning this off stops future captures; queued messages keep the context captured when they were sent.", bundle: .module)
        }
        .onAppear { model.refresh() }
    }

    private func status(_ status: LocationContextModel.Status, accuracy: String?) -> String {
        switch status {
        case .off: L("Location sharing is off")
        case .permissionRequired: L("Allow location access to share context")
        case .denied: L("Location access is denied")
        case .restricted: L("Location access is restricted on this device")
        case .locating: L("Getting device location…")
        case .ready:
            if let accuracy { L("Location context is ready to share · \(accuracy)") }
            else { L("Location context is ready to share") }
        case .unavailable: L("Location is unavailable. Messages send without it.")
        }
    }

    private static func openSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
