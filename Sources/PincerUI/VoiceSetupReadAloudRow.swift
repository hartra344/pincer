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
            LabeledContent(L("Gateway voice")) {
                Text(self.summary(gateway))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if let reason = ReadAloudController.shared.lastFallback {
                Label(reason.message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(L("Open Gateway Voice Settings")) { self.open(gateway) }
        }
    }

    private func summary(_ gateway: GatewayStore) -> String {
        switch gateway.voice.readAloudSummary {
        case let .automatic(provider, model, name):
            let voice = model.map { "\(provider) (\($0))" } ?? provider
            return String(format: L("Automatic: %@ via %@"), voice, name.isEmpty ? gateway.profile.name : name)
        case let .fallback(reason):
            return String(format: L("Using this device's voice: %@"), reason.message)
        }
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
