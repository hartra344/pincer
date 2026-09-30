import PincerKit
import SwiftUI

/// Top of the Voice page: is the Gateway voice working?
struct VoiceSetupStatusSection: View {
    let model: GatewayVoiceModel
    let status: TTSStatus

    private var active: String { self.status.provider }
    private var badge: TTSProviderBadge { self.model.badge(for: self.active) }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                switch (self.active.isEmpty || !self.status.hasConfiguredProvider, self.model.providerProblem(for: self.active), self.badge) {
                case (true, nil, _):
                    Label(L("Gateway Voice: Not set up"), systemImage: "speaker.slash").font(.headline)
                    Text("Read Aloud uses this device's voice until a provider is ready.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                case let (_, problem?, _):
                    Label(String(format: L("%@ isn't working"), self.model.displayName(for: self.active)), systemImage: "xmark.octagon.fill")
                        .font(.headline).foregroundStyle(.red)
                    Text(problem.message).font(.caption).foregroundStyle(.secondary)
                    Text(self.advice(problem.cause)).font(.caption).foregroundStyle(.secondary)
                case (_, _, .needsKey):
                    Label(String(format: L("%@ needs a key"), self.model.displayName(for: self.active)), systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text("Read Aloud uses this device's voice until a provider is ready.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    HStack {
                        Text(self.summary).font(.headline)
                        Spacer()
                        VoiceBadge(badge: .ready)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func advice(_ cause: TTSProviderProblem.Cause) -> String {
        switch cause {
        case .key: L("Check the API key below, then run Test Voice.")
        case .model: L("Choose a different model below, then run Test Voice.")
        case .voice: L("Choose a different voice below, then run Test Voice.")
        case .other: L("Run Test Voice again, or check the settings below.")
        }
    }

    private var summary: String {
        let setup = self.model.setups[self.active]
        let keys = TTSProviderKeys.forProvider(self.active)
        var parts = [self.model.displayName(for: self.active)]
        if keys.model != nil { parts.append(self.model.modelDisplay(setup?.model, provider: self.active)) }
        if keys.voice != nil { parts.append(self.model.voiceDisplay(setup?.voice, provider: self.active)) }
        return parts.joined(separator: " · ")
    }
}
