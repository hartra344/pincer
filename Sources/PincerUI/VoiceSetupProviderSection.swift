import PincerKit
import SwiftUI

/// Section 1: the Gateway's TTS providers with their status. Selecting one shows its setup below; it
/// doesn't make it active.
struct VoiceSetupProviderSection: View {
    let model: GatewayVoiceModel
    let setup: VoiceSetupController
    let status: TTSStatus
    let selected: String
    /// The key section shows its own button right after a key was saved.
    var hideUseButton = false

    private var rows: [TTSProviderState] {
        if !self.model.providers.isEmpty {
            return self.model.providers.map { TTSProviderState(id: $0.id, label: $0.name, configured: $0.configured) }
        }
        return self.status.providerStates
    }

    var body: some View {
        Section {
            ForEach(self.rows, id: \.id) { row in self.row(row.id) }
            if !self.hideUseButton {
                VoiceUseProviderButton(model: self.model, setup: self.setup, provider: self.selected)
            }
            VoiceScopedMessage(setup: self.setup, scope: "provider")
        } header: {
            Text("Provider", bundle: .module)
        } footer: {
            Text("Choose a provider to set it up below. Providers that need a key show Needs Key until you add one.", bundle: .module)
        }
    }

    private func row(_ id: String) -> some View {
        let badge = self.model.badge(for: id)
        let inUse = id == self.status.provider
        let name = self.model.displayName(for: id)
        return Button { self.setup.selectedProvider = id } label: {
            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(name).foregroundStyle(.primary)
                        if inUse { VoiceInUseTag() }
                        Spacer(minLength: 8)
                        VoiceBadge(badge: badge)
                        self.marker(id)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(name).foregroundStyle(.primary); if inUse { VoiceInUseTag() }; Spacer(); self.marker(id) }
                        VoiceBadge(badge: badge)
                    }
                }
                if case let .error(reason) = badge {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityLabel(name: name, badge: badge, inUse: inUse))
        .accessibilityAddTraits(id == self.selected ? .isSelected : [])
    }

    @ViewBuilder private func marker(_ id: String) -> some View {
        if id == self.selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true) }
    }

    private func accessibilityLabel(name: String, badge: TTSProviderBadge, inUse: Bool) -> String {
        let state: String = switch badge {
        case .ready: L("Ready")
        case .needsKey: L("Needs Key")
        case let .error(reason): "\(L("Not Working")): \(reason)"
        }
        return [name, inUse ? L("In Use") : nil, state].compactMap { $0 }.joined(separator: ", ")
    }
}
