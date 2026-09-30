import PincerKit
import SwiftUI

/// Settings → Appearance → Avatars: the animated companions on or off, pixel or plush, and which
/// creature each agent is. The style and characters sync to your other devices through each
/// Gateway's `users.prefs`; animated on or off stays on this device.
struct AvatarSettingsSection: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AvatarSettings.animatedKey) private var enabled = true
    @AppStorage(AvatarSettings.renderStyleKey) private var renderStyle = AvatarRenderStyle.pixel.rawValue

    /// Agents across connected Gateways, once each by id (the style is keyed by agent id).
    private var agents: [AgentSummary] {
        var seen = Set<String>()
        return self.app.gateways.flatMap(\.agents).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        SwiftUI.Section {
            Toggle(isOn: self.$enabled) {
                Text("Animated avatars", bundle: .module)
                Text("Each agent gets a little companion that shows what it's doing. Off keeps the initial or emoji.", bundle: .module)
            }
            if self.enabled {
                Picker(L("Style"), selection: Binding(get: { self.renderStyle }, set: { self.setRenderStyle($0) })) {
                    Text("Pixel", bundle: .module).tag(AvatarRenderStyle.pixel.rawValue)
                    Text("Plush", bundle: .module).tag(AvatarRenderStyle.plush.rawValue)
                }
                .pickerStyle(.segmented)
                ForEach(self.agents) { agent in
                    AvatarCharacterRow(agent: agent,
                                       gateways: self.app.gateways.filter { $0.agents.contains { $0.id == agent.id } })
                }
            }
        } header: {
            Text("Avatars", bundle: .module)
        } footer: {
            if self.enabled {
                Text("Auto keeps the character the agent first got from its identity. Style and characters sync to your other devices through the Gateway. Reduce Motion keeps them still.", bundle: .module)
            }
        }
    }

    private func setRenderStyle(_ value: String) {
        self.renderStyle = value
        guard let style = AvatarRenderStyle(rawValue: value) else { return }
        for gateway in self.app.gateways { gateway.setAvatarRenderStyle(style) }
    }
}

/// One agent's still preview and Character picker; used in Settings and on the agent's page.
struct AvatarCharacterRow: View {
    let agent: AgentSummary
    /// Gateways that have this agent, which sync its character.
    let gateways: [GatewayStore]
    var previewSize: CGFloat = 28
    @AppStorage(AvatarSettings.renderStyleKey) private var renderStyle = AvatarRenderStyle.pixel.rawValue
    @AppStorage private var creature: String

    init(agent: AgentSummary, gateways: [GatewayStore], previewSize: CGFloat = 28) {
        self.agent = agent
        self.gateways = gateways
        self.previewSize = previewSize
        self._creature = AppStorage(wrappedValue: "", AvatarSettings.creatureKey(for: agent.id))
    }

    private var style: AvatarStyle {
        let seed = self.gateways.first?.avatarSeed(for: self.agent)
            ?? AvatarStyle.identitySeed(name: self.agent.name, agentId: self.agent.id)
        return AvatarSettings.style(for: self.agent, seed: seed, creature: self.creature, renderStyle: self.renderStyle)
    }

    var body: some View {
        Picker(selection: Binding(get: { self.creature }, set: { self.setCreature($0) })) {
            Text("Auto", bundle: .module).tag("")
            ForEach(AvatarCreature.allCases, id: \.self) { creature in
                Text(creature.rawValue.capitalized).tag(creature.rawValue)
            }
        } label: {
            self.label
        }
        .accessibilityLabel(L("\(self.agent.name) character"))
    }

    private var label: some View {
        HStack(spacing: Theme.Spacing.md) {
            AgentAvatarView(state: .idle, style: self.style, size: self.previewSize, seed: self.agent.id)
                .accessibilityHidden(true)
            Text(self.agent.name)
        }
    }

    private func setCreature(_ value: String) {
        self.creature = value
        for gateway in self.gateways { gateway.setAvatarCreature(AvatarCreature(rawValue: value), for: self.agent.id) }
    }
}
