import PincerKit
import SwiftUI

/// Settings → Read Aloud: which voice "Automatic" will use on the selected Gateway, and a way into
/// Gateway Settings → Voice to change it.
struct ReadAloudGatewayVoiceRows: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openGatewaySettings) private var openGatewaySettings
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @Environment(\.dismiss) private var dismiss
    #endif

    private var gateway: GatewayStore? { self.app.selectedGateway ?? self.app.gateways.first }

    var body: some View {
        if let gateway = self.gateway {
            LabeledContent(L("Gateway Voice")) {
                Text(self.summary(gateway))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button(L("Open Gateway Voice Settings")) { self.open(gateway) }
        }
    }

    private func summary(_ gateway: GatewayStore) -> String {
        let voice = gateway.voice
        let name = gateway.profile.name
        guard voice.supportsStatus, voice.supports(GatewayVoiceModel.speakMethod) else {
            return L("This Gateway can't speak; Read Aloud uses this device's voice.")
        }
        guard voice.canWrite else {
            return L("This device can't use the Gateway's voice; Read Aloud uses this device's voice.")
        }
        guard let status = voice.status else { return L("Open Gateway Voice Settings to check.") }
        let provider = voice.providers.first { $0.id == status.provider }?.name
            ?? status.providerStates.first { $0.id == status.provider }?.label ?? status.provider
        guard voice.canSpeak else {
            return L("No Gateway voice is set up; Read Aloud uses this device's voice.")
        }
        return L("Automatic: \(provider) via \(name)")
    }

    private func open(_ gateway: GatewayStore) {
        #if os(macOS)
        gateway.settings.requestedRoutes = []
        gateway.settings.requestedDestination = .voice
        self.openWindow(id: "gateway-settings", value: gateway.id)
        #else
        // The app Settings sheet is in the way of a second sheet, so close it first.
        let opener = self.openGatewaySettings
        self.dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            opener(gateway, at: .voice)
        }
        #endif
    }
}
