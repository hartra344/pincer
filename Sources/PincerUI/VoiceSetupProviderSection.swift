import PincerKit
import SwiftUI

/// Section 1: the Gateway's TTS providers with their status. Selecting one shows its setup; "Use for
/// Gateway voice" makes it the active provider once it's Ready.
struct VoiceSetupProviderSection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let status: TTSStatus

    private var rows: [TTSProviderState] {
        if !self.model.providers.isEmpty {
            return self.model.providers.map { TTSProviderState(id: $0.id, label: $0.name, configured: $0.configured) }
        }
        return self.status.providerStates
    }

    var body: some View {
        Section {
            ForEach(self.rows, id: \.id) { row in
                Button { self.setup.selectedProvider = row.id } label: {
                    HStack {
                        Text(self.model.displayName(for: row.id))
                            .foregroundStyle(.primary)
                        if row.id == self.status.provider {
                            Text("In use", bundle: .module).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VoiceBadge(badge: self.model.badge(for: row.id))
                        if row.id == self.setup.selectedProvider {
                            Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(row.id == self.setup.selectedProvider ? .isSelected : [])
            }
            if let selected = self.setup.selectedProvider, selected != self.status.provider {
                Button(L("Use for Gateway voice")) {
                    Task { await self.setup.run { try await self.model.setProvider(selected); return nil } }
                }
                .disabled(!self.model.canWrite || self.model.badge(for: selected) != .ready)
            }
        } header: {
            Text("Provider", bundle: .module)
        } footer: {
            Text("Choose a provider to set it up below. A provider needs an API key before it can be used.", bundle: .module)
        }
    }
}
