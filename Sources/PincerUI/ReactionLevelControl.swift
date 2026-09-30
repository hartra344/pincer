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

    func localizedDetail(channel: String) -> String {
        switch self {
        case .off:
            offAlsoStopsAcknowledgement(channel: channel)
                ? L("The agent never reacts. Also turns off the 👀 acknowledgement.") : L("The agent never reacts.")
        case .ack: L("The agent doesn't react itself. The 👀 acknowledgement still shows if it's set up.")
        case .minimal: L("The agent reacts now and then, when it fits.")
        case .extensive: L("The agent reacts freely.")
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
            Text(effective.level.localizedDetail(channel: self.channel))
            if effective.isInvalid {
                Text("The stored value isn't a valid level, so the agent uses \(effective.level.localizedTitle).", bundle: .module)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// The chat ⋯ menu's shortcut: the level for this chat's channel (or account), written at once.
/// It is channel-wide, so the menu says which chats it applies to.
struct ReactionLevelMenu: View {
    let row: SessionRow
    @Environment(GatewayStore.self) private var gateway

    var body: some View {
        if let target = ReactionLevels.target(of: self.row), self.gateway.canEditReactionLevels {
            let settings = self.gateway.settings
            let account = ReactionLevels.overridingAccount(config: settings.config, channel: target.channel, account: target.account)
            let effective = ReactionLevels.effective(config: settings.config, channel: target.channel, account: account)
            Menu {
                Section(self.scope(target.channel, account)) {
                    ForEach(ReactionLevel.allCases) { level in
                        Toggle(level.localizedTitle, isOn: self.isOn(target.channel, account, level, effective.level))
                    }
                }
                Text(ReactionLevelText.summary(effective, hasAccount: account != nil))
            } label: {
                Label(L("Reactions"), systemImage: "face.smiling")
            }
        }
    }

    private func scope(_ channel: String, _ account: String?) -> String {
        let name = ReactionLevels.displayName(channel: channel)
        guard let account else { return L("Applies to all \(name) chats") }
        return L("Applies to all chats on \(self.accountName(channel, account))")
    }

    private func accountName(_ channel: String, _ account: String) -> String {
        let status = self.gateway.channels.snapshot?.channel(channel)?.effectiveAccounts.first { $0.accountId == account }?.name
        let configured = self.gateway.settings.config["channels"]?[channel]?["accounts"]?[account]?["name"]?.text
        return [status, configured].compactMap { $0 }.first { !$0.isEmpty } ?? account
    }

    private func isOn(_ channel: String, _ account: String?, _ level: ReactionLevel, _ current: ReactionLevel) -> Binding<Bool> {
        Binding(get: { level == current }, set: { _ in
            guard level != current else { return }
            let chat = self.gateway.chat(for: self.row.key)
            Task {
                if let failure = await self.gateway.settings.saveReactionLevel(channel: channel, account: account, level: level) {
                    chat.notice = failure
                }
            }
        })
    }
}
