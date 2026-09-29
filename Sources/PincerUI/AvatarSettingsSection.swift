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
                    AvatarCharacterRow(agent: agent, renderStyle: self.renderStyle,
                                       gateways: self.app.gateways.filter { $0.agents.contains { $0.id == agent.id } })
                }
            }
        } header: {
            Text("Avatars", bundle: .module)
        } footer: {
            if self.enabled {
                Text("Auto picks a character from the agent's identity. Style and characters sync to your other devices through the Gateway. Reduce Motion keeps them still.", bundle: .module)
            }
        }
    }

    private func setRenderStyle(_ value: String) {
        self.renderStyle = value
        guard let style = AvatarRenderStyle(rawValue: value) else { return }
        for gateway in self.app.gateways { gateway.setAvatarRenderStyle(style) }
    }
}

private struct AvatarCharacterRow: View {
    let agent: AgentSummary
    let renderStyle: String
    /// Gateways that have this agent, which sync its character.
    let gateways: [GatewayStore]
    @AppStorage private var creature: String

    init(agent: AgentSummary, renderStyle: String, gateways: [GatewayStore]) {
        self.agent = agent
        self.renderStyle = renderStyle
        self.gateways = gateways
        self._creature = AppStorage(wrappedValue: "", AvatarSettings.creatureKey(for: agent.id))
    }

    var body: some View {
        let style = AvatarSettings.style(for: self.agent, creature: self.creature, renderStyle: self.renderStyle)
        Picker(selection: Binding(get: { self.creature }, set: { self.setCreature($0) })) {
            Text("Auto", bundle: .module).tag("")
            ForEach(AvatarCreature.allCases, id: \.self) { creature in
                Text(creature.rawValue.capitalized).tag(creature.rawValue)
            }
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                AgentAvatarView(state: .idle, style: style, size: 28, seed: self.agent.id)
                    .accessibilityHidden(true)
                Text(self.agent.name)
            }
        }
        .accessibilityLabel(L("\(self.agent.name) character"))
    }

    private func setCreature(_ value: String) {
        self.creature = value
        for gateway in self.gateways { gateway.setAvatarCreature(AvatarCreature(rawValue: value), for: self.agent.id) }
    }
}
