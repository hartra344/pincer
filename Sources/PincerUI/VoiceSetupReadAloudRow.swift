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

    @AppStorage(ReadAloudSettings.sourceKey) private var source = ReadAloudSettings.sourceAutomatic

    private var gateway: GatewayStore? { self.app.selectedGateway ?? self.app.gateways.first }

    var body: some View {
        LabeledContent(L("Gateway Voice")) {
            self.summary
                .multilineTextAlignment(.trailing)
        }
        if let reason = ReadAloudController.shared.lastFallback {
            Text(String(format: L("Last reply used this device's voice: %@"), reason.message))
                .font(.caption).foregroundStyle(.secondary)
        }
        Button(L("Open Gateway Voice Settings…")) { if let gateway = self.gateway { self.open(gateway) } }
            .disabled(self.gateway == nil)
    }

    @ViewBuilder private var summary: some View {
        if self.source == ReadAloudSettings.sourceDevice {
            Text("Not used (This Device Only)", bundle: .module).foregroundStyle(.secondary)
        } else if let gateway = self.gateway, gateway.state.isConnected {
            switch gateway.voice.readAloudSummary {
            case let .automatic(provider, model, name):
                let voice = model.map { "\(provider) (\($0))" } ?? provider
                Text(String(format: L("%@ via %@"), voice, name.isEmpty ? gateway.profile.name : name)).foregroundStyle(.secondary)
            case let .gatewayFallback(selected, reason, using):
                let tail = using.map { String(format: L("Using %@."), $0) } ?? L("Using this device's voice.")
                Label(String(format: L("%@ can't be used: %@. %@"), selected, Self.shortReason(reason), tail), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .fallback(.notConfigured):
                Text("Not set up. Using this device's voice.", bundle: .module).foregroundStyle(.secondary)
            case let .fallback(reason):
                Label(String(format: L("Using this device's voice: %@"), reason.message), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Gateway not connected. Using this device's voice.", bundle: .module).foregroundStyle(.secondary)
        }
    }

    /// The reason as a clause without a trailing full stop or the provider's name.
    static func shortReason(_ reason: TTSFallbackReason) -> String {
        switch reason {
        case .keyNotResolving: return L("the Gateway can't read its key")
        case .notConfigured: return L("it isn't set up on the Gateway yet")
        case .modelRejected: return L("it rejected the model or voice")
        default:
            let text = reason.message.trimmingCharacters(in: .whitespaces)
            return text.hasSuffix(".") ? String(text.dropLast()) : text
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
