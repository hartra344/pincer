import PincerKit
import SwiftUI

/// Settings → Appearance → Avatars: the animated companions on or off, pixel or plush, and which
/// creature each agent is. The style and characters sync to your other devices through each
/// Gateway's `users.prefs`; animation and compact chat-header size stay on this device.
struct AvatarSettingsSection: View {
    @Environment(AppModel.self) private var app
    @AppStorage(AvatarSettings.animatedKey) private var enabled = true
    @AppStorage(AvatarSettings.renderStyleKey) private var renderStyle = AvatarRenderStyle.pixel.rawValue

    /// Kept as a projection so the row policy can be exercised without constructing the full Settings window.
    private var settingRows: [AvatarSettingsRow] {
        Self.settingRows(for: self.app.gateways)
    }

    static func settingRows(for gateways: [GatewayStore]) -> [AvatarSettingsRow] {
        gateways.flatMap { gateway in
            gateway.agents.map { agent in
                AvatarSettingsRow(agent: agent, gateway: gateway)
            }
        }
    }

    var body: some View {
        SwiftUI.Section {
            #if os(iOS)
            ChatHeaderAvatarSizePicker()
            #endif
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
                ForEach(self.settingRows) { row in
                    AvatarCharacterRow(agent: row.agent, gateways: [row.gateway], gatewayName: row.gateway.profile.name)
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

#if os(iOS)
/// Shares the device-local storage key with the actual compact header.
struct ChatHeaderAvatarSizePicker: View {
    @AppStorage(ChatHeaderAvatarSize.defaultsKey) private var size = ChatHeaderAvatarSize.small.rawValue
    var body: some View {
        Picker(L("Chat header avatar"), selection: Binding(
            get: { ChatHeaderAvatarSize(normalizing: self.size).rawValue }, set: { self.size = $0 })) {
            Text("Small", bundle: .module).tag(ChatHeaderAvatarSize.small.rawValue)
            Text("Large", bundle: .module).tag(ChatHeaderAvatarSize.large.rawValue)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("chat-header-avatar-size")
    }
}
#endif

struct AvatarSettingsRow: Identifiable {
    let agent: AgentSummary
    let gateway: GatewayStore

    var id: String { "\(self.gateway.id.uuidString):\(self.agent.id)" }
}

/// One agent's still preview and Character picker; used in Settings and on the agent's page.
struct AvatarCharacterRow: View {
    let agent: AgentSummary
    /// Gateways that have this agent, which sync its character.
    let gateways: [GatewayStore]
    var gatewayName: String? = nil
    var previewSize: CGFloat = 28
    @AppStorage(AvatarSettings.renderStyleKey) private var renderStyle = AvatarRenderStyle.pixel.rawValue

    private var creature: String {
        guard let gateway = self.gateways.first else {
            return UserDefaults.standard.string(forKey: AvatarSettings.creatureKey(for: self.agent.id)) ?? ""
        }
        return gateway.avatarCreature(for: self.agent.id)?.rawValue ?? ""
    }

    init(agent: AgentSummary, gateways: [GatewayStore], gatewayName: String? = nil, previewSize: CGFloat = 28) {
        self.agent = agent
        self.gateways = gateways
        self.previewSize = previewSize
        self.gatewayName = gatewayName
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
        .accessibilityLabel(self.gatewayName.map { L("\(self.agent.name) character, \($0)") }
            ?? L("\(self.agent.name) character"))
    }

    private var label: some View {
        HStack(spacing: Theme.Spacing.md) {
            AgentAvatarView(state: .idle, style: self.style, size: self.previewSize, seed: self.agent.id)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(self.agent.name)
                if let gatewayName = self.gatewayName {
                    Text(gatewayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func setCreature(_ value: String) {
        Self.selectCreature(value, agentId: self.agent.id, gateways: self.gateways)
    }

    /// Applies a picker choice to its owning Gateway. Passing defaults is reserved for a row without
    /// Gateway context, which retains the historical device-local behavior.
    static func selectCreature(
        _ value: String,
        agentId: String,
        gateways: [GatewayStore],
        defaults: UserDefaults? = nil)
    {
        if let defaults {
            if gateways.isEmpty {
                defaults.set(value, forKey: AvatarSettings.creatureKey(for: agentId))
            }
        }
        for gateway in gateways { gateway.setAvatarCreature(AvatarCreature(rawValue: value), for: agentId) }
    }
}
