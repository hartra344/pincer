import PincerKit
import SwiftUI

/// Settings → Appearance → Avatars: the animated companions on or off, pixel or plush, and which
/// creature each agent is. Stored on this device only.
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
                Text("Animated avatars")
                Text("Each agent gets a little companion that shows what it's doing. Off keeps the initial or emoji.")
            }
            if self.enabled {
                Picker("Style", selection: self.$renderStyle) {
                    Text("Pixel").tag(AvatarRenderStyle.pixel.rawValue)
                    Text("Plush").tag(AvatarRenderStyle.plush.rawValue)
                }
                .pickerStyle(.segmented)
                ForEach(self.agents) { agent in
                    AvatarCharacterRow(agent: agent, renderStyle: self.renderStyle)
                }
            }
        } header: {
            Text("Avatars")
        } footer: {
            if self.enabled {
                Text("Auto picks a character from the agent's identity. Reduce Motion keeps them still.")
            }
        }
    }
}

private struct AvatarCharacterRow: View {
    let agent: AgentSummary
    let renderStyle: String
    @AppStorage private var creature: String

    init(agent: AgentSummary, renderStyle: String) {
        self.agent = agent
        self.renderStyle = renderStyle
        self._creature = AppStorage(wrappedValue: "", AvatarSettings.creatureKey(for: agent.id))
    }

    var body: some View {
        let style = AvatarSettings.style(for: self.agent, creature: self.creature, renderStyle: self.renderStyle)
        Picker(selection: self.$creature) {
            Text("Auto").tag("")
            ForEach(AvatarCreature.allCases, id: \.self) { creature in
                Text(creature.rawValue.capitalized).tag(creature.rawValue)
            }
        } label: {
            HStack(spacing: 8) {
                AgentAvatarView(state: .idle, style: style, size: 28, seed: self.agent.id)
                    .accessibilityHidden(true)
                Text(self.agent.name)
            }
        }
        .accessibilityLabel("\(self.agent.name) character")
    }
}
