import PincerKit
import SwiftUI

extension ReactionLevel {
    var localizedTitle: String {
        switch self {
        case .off: L("Off")
        case .ack: L("Acknowledge only")
        case .minimal: L("Minimal")
        case .extensive: L("Extensive")
        }
    }

    var localizedDetail: String {
        switch self {
        case .off: L("No acknowledgement reaction and no agent reactions.")
        case .ack: L("Only the 👀 acknowledgement while the agent works.")
        case .minimal: L("The agent reacts sparingly. No acknowledgement.")
        case .extensive: L("The agent reacts liberally. No acknowledgement.")
        }
    }
}

enum ReactionLevelText {
    /// "Minimal · Default", "Extensive · Set for the channel" …
    static func summary(_ effective: ReactionLevels.Effective, hasAccount: Bool) -> String {
        let level = effective.level.localizedTitle
        switch effective.source {
        case .account: return L("\(level) · Set for this account")
        case .channel: return hasAccount ? L("\(level) · Inherited from the channel") : L("\(level) · Set for the channel")
        case .default: return L("\(level) · Default")
        }
    }

    static func inheritTitle(channel: String, config: JSONValue?, hasAccount: Bool) -> String {
        let inherited = ReactionLevels.effective(config: config, channel: channel, account: nil)
        let level = inherited.level.localizedTitle
        return hasAccount ? L("Same as channel (\(level))") : L("Default (\(level))")
    }
}

/// "How freely the agent reacts" for one channel or one of its accounts, in Gateway Settings. It edits the
/// same staged config as the schema editor (which leaves this key out), so Save sends it with everything else.
struct ReactionLevelSection: View {
    let channel: String
    var account: String?
    @Environment(GatewayStore.self) private var gateway

    private var path: [String] { ReactionLevels.path(channel: self.channel, account: self.account) }

    var body: some View {
        if ReactionLevels.supports(channel: self.channel), self.gateway.canEditReactionLevels {
            let settings = self.gateway.settings
            let config = settings.config
            let effective = ReactionLevels.effective(config: config, channel: self.channel, account: self.account)
            Section {
                Picker(L("How freely the agent reacts"), selection: self.binding(settings)) {
                    Text(ReactionLevelText.inheritTitle(channel: self.channel, config: config, hasAccount: self.account != nil))
                        .tag(ReactionLevel?.none)
                    ForEach(ReactionLevel.allCases) { level in
                        Text(level.localizedTitle).tag(ReactionLevel?.some(level))
                    }
                }
                .id(ConfigPath.string(self.path))
                LabeledContent(L("In effect")) {
                    Text(ReactionLevelText.summary(effective, hasAccount: self.account != nil)).foregroundStyle(.secondary)
                }
            } header: {
                Text("Reactions", bundle: .module)
            } footer: {
                self.footer(effective)
            }
        }
    }

    private func binding(_ settings: GatewaySettingsModel) -> Binding<ReactionLevel?> {
        Binding(
            get: { settings.value(at: self.path)?.string.flatMap { ReactionLevel(rawValue: $0) } },
            set: { settings.set(self.path, $0.map { .string($0.rawValue) }) })
    }

    private func footer(_ effective: ReactionLevels.Effective) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(effective.level.localizedDetail)
            if effective.isInvalid {
                Text("The stored value isn't a valid level, so the agent uses this fallback.", bundle: .module)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// The chat ⋯ menu's shortcut: the level for this chat's channel (or account), written at once.
struct ReactionLevelMenu: View {
    let row: SessionRow
    @Environment(GatewayStore.self) private var gateway
    @State private var failure: String?

    var body: some View {
        if let target = ReactionLevels.target(of: self.row), self.gateway.canEditReactionLevels {
            let settings = self.gateway.settings
            let account = ReactionLevels.editableAccount(config: settings.config, channel: target.channel, account: target.account)
            let effective = ReactionLevels.effective(config: settings.config, channel: target.channel, account: account)
            Menu {
                Picker(L("How freely the agent reacts"), selection: self.binding(target.channel, account, effective.level)) {
                    ForEach(ReactionLevel.allCases) { level in
                        Text(level.localizedTitle).tag(level)
                    }
                }
                .pickerStyle(.inline)
                Text(ReactionLevelText.summary(effective, hasAccount: account != nil))
            } label: {
                Label(L("Reactions"), systemImage: "face.smiling")
            }
            .alert(L("Couldn't Change Reactions"), isPresented: Binding(get: { self.failure != nil },
                                                                        set: { if !$0 { self.failure = nil } })) {
                Button(L("OK"), role: .cancel) {}
            } message: {
                Text(self.failure ?? "")
            }
            .task(id: self.gateway.state.isConnected) {
                if self.gateway.state.isConnected, !settings.hasLoaded { await settings.load() }
            }
        }
    }

    private func binding(_ channel: String, _ account: String?, _ current: ReactionLevel) -> Binding<ReactionLevel> {
        Binding(get: { current }, set: { level in
            guard level != current else { return }
            Task { self.failure = await self.gateway.settings.saveReactionLevel(channel: channel, account: account, level: level) }
        })
    }
}
