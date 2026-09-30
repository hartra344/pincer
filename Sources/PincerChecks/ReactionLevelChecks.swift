import Foundation
import PincerKit

// The per-channel reactionLevel control (#107): resolution and patch building offline, then the
// demo's seeded config and a (mock) Gateway's config.patch round-trip.

private func config(_ text: String) -> JSONValue { json(text) }

@MainActor
func checkReactionLevel() {
    check(ReactionLevel.allCases.map(\.rawValue) == ["off", "ack", "minimal", "extensive"]
          && ReactionLevel.allCases.map(\.title) == ["Off", "Acknowledge only", "Minimal", "Extensive"], "levels and titles")
    check(ReactionLevels.supports(channel: "telegram") && ReactionLevels.supports(channel: "whatsapp") && ReactionLevels.supports(channel: "signal")
          && !ReactionLevels.supports(channel: "discord"), "Telegram, WhatsApp and Signal take a level; Discord doesn't")
    let empty = ReactionLevels.effective(config: config("{}"), channel: "whatsapp", account: nil)
    check(empty.source == .default && empty.level == ReactionLevels.defaultLevel(channel: "whatsapp"), "no config → the channel default")
    let cfg = config(#"{"channels":{"telegram":{"reactionLevel":"minimal","accounts":{"home":{"reactionLevel":"extensive"},"work":{}}}}}"#)
    let home = ReactionLevels.effective(config: cfg, channel: "telegram", account: "home")
    let work = ReactionLevels.effective(config: cfg, channel: "telegram", account: "work")
    let chan = ReactionLevels.effective(config: cfg, channel: "telegram", account: nil)
    check(home.level == .extensive && home.source == .account, "account beats channel")
    check(work.level == .minimal && work.source == .channel && chan.level == .minimal && chan.source == .channel, "channel applies to accounts without their own")
    let bad = ReactionLevels.effective(config: config(#"{"channels":{"telegram":{"reactionLevel":"loud"}}}"#), channel: "telegram", account: nil)
    check(bad.level == ReactionLevels.invalidFallback(channel: "telegram") && bad.isInvalid, "invalid value → the channel's invalid fallback")
    let blank = ReactionLevels.effective(config: config(#"{"channels":{"telegram":{"reactionLevel":"  "}}}"#), channel: "telegram", account: nil)
    check(blank.source == .default, "blank value counts as missing")
    check(ReactionLevel.off.offAlsoStopsAcknowledgement(channel: "whatsapp") && ReactionLevel.off.offAlsoStopsAcknowledgement(channel: "signal")
          && !ReactionLevel.off.offAlsoStopsAcknowledgement(channel: "telegram") && !ReactionLevel.ack.offAlsoStopsAcknowledgement(channel: "whatsapp"),
          "Off also stops the 👀 on WhatsApp and Signal, not Telegram")
    check(ReactionLevels.overridingAccount(config: cfg, channel: "telegram", account: "home") == "home"
          && ReactionLevels.overridingAccount(config: cfg, channel: "telegram", account: "work") == nil
          && ReactionLevels.overridingAccount(config: cfg, channel: "telegram", account: nil) == nil,
          "a chat edits its account only when that account has its own level")
    check(ReactionLevels.patch(channel: "telegram", account: nil, level: .ack) == ["channels": ["telegram": ["reactionLevel": "ack"]]], "channel patch")
    check(ReactionLevels.patch(channel: "telegram", account: "home", level: .off)
          == ["channels": ["telegram": ["accounts": ["home": ["reactionLevel": "off"]]]]], "account patch")
    check(ReactionLevels.patch(channel: "signal", account: nil, level: nil) == ["channels": ["signal": ["reactionLevel": .null]]], "clearing an override patches null")
}

/// The seeded config: Telegram "minimal" with a "home" account override, WhatsApp unset, Discord without a control.
@MainActor
private func checkSeededLevels(_ settings: GatewaySettingsModel, label: String) {
    let cfg = settings.config
    let telegram = ReactionLevels.effective(config: cfg, channel: "telegram", account: "default")
    let home = ReactionLevels.effective(config: cfg, channel: "telegram", account: "home")
    let whatsapp = ReactionLevels.effective(config: cfg, channel: "whatsapp", account: nil)
    check(telegram.level == .minimal && telegram.source == .channel, "\(label): Telegram inherits the channel's minimal")
    check(home.level == .extensive && home.source == .account, "\(label): the home account overrides to extensive")
    check(whatsapp.source == .default, "\(label): WhatsApp shows the default")
    check(!ReactionLevels.supports(channel: "discord"), "\(label): Discord has no control")
}

@MainActor
func runDemoReactionLevel() async {
    let gateway = GatewayStore(profile: .demo())
    gateway.start()
    let connected = await waitFor("demo for reaction level") { gateway.state.isConnected && !gateway.sessions.isEmpty }
    check(connected, "demo connected")
    defer { gateway.stop() }
    guard connected else { return }
    await gateway.settings.load()
    check(gateway.settings.hasLoaded, "demo config loads")
    checkSeededLevels(gateway.settings, label: "demo")
    let telegramRow = gateway.sessions["agent:main:telegram:home:direct:5550142"]
    let target = telegramRow.flatMap { ReactionLevels.target(of: $0) }
    check(target?.channel == "telegram" && target?.account == "home", "the bridged Telegram chat maps to the home account (\(String(describing: target)))")
    if gateway.settings.canEdit {
        let error = await gateway.settings.saveReactionLevel(channel: "whatsapp", account: nil, level: .ack)
        check(error == nil, "demo saves a level (\(error ?? "ok"))")
        check(ReactionLevels.effective(config: gateway.settings.config, channel: "whatsapp", account: nil).level == .ack
              && ReactionLevels.effective(config: gateway.settings.config, channel: "whatsapp", account: nil).source == .channel, "the saved level is effective")
    }
}

@MainActor
func runLiveReactionLevel(url: String, token: String) async {
    let profile = GatewayProfile(name: "Mock reaction level", url: url, authMode: .token, access: .admin)
    profile.secret = token
    let gateway = GatewayStore(profile: profile)
    gateway.start()
    let connected = await waitFor("admin connection") { gateway.state.isConnected && gateway.hello != nil }
    check(connected && gateway.settings.canEdit, "admin scope granted")
    defer { gateway.stop() }
    guard connected else { return }
    let settings = gateway.settings
    await settings.load()
    checkSeededLevels(settings, label: "mock")

    // Channel level: set, then clear (back to the default).
    var saved = await settings.saveReactionLevel(channel: "whatsapp", account: nil, level: .extensive)
    check(saved == nil, "config.patch sets the channel level")
    var effective = ReactionLevels.effective(config: settings.config, channel: "whatsapp", account: nil)
    check(effective.level == .extensive && effective.source == .channel, "the Gateway echoes it back (\(effective.level))")
    saved = await settings.saveReactionLevel(channel: "whatsapp", account: nil, level: nil)
    check(saved == nil, "clearing patches null")
    effective = ReactionLevels.effective(config: settings.config, channel: "whatsapp", account: nil)
    check(effective.source == .default && settings.config["channels"]?["whatsapp"]?["reactionLevel"] == nil, "cleared → key removed, default again")

    // Account override: change and clear (falls back to the channel).
    saved = await settings.saveReactionLevel(channel: "telegram", account: "home", level: .off)
    check(saved == nil, "config.patch sets an account level")
    effective = ReactionLevels.effective(config: settings.config, channel: "telegram", account: "home")
    check(effective.level == .off && effective.source == .account, "account level saved")
    check(ReactionLevels.effective(config: settings.config, channel: "telegram", account: "default").level == .minimal, "other accounts unaffected")
    saved = await settings.saveReactionLevel(channel: "telegram", account: "home", level: nil)
    check(saved == nil, "clearing an account override")
    effective = ReactionLevels.effective(config: settings.config, channel: "telegram", account: "home")
    check(effective.level == .minimal && effective.source == .channel, "cleared account inherits the channel")

    // A second connection sees the same config; restore the seeded override.
    saved = await settings.saveReactionLevel(channel: "telegram", account: "home", level: .extensive)
    check(saved == nil, "seeded override restored")
    let other = GatewayStore(profile: profile)
    other.start()
    if await waitFor("second admin connection", { other.state.isConnected && other.hello != nil }) {
        await other.settings.load()
        checkSeededLevels(other.settings, label: "second connection")
        other.stop()
    }

    // Without operator.admin the control is read-only.
    let plain = GatewayProfile(name: "Mock reaction level (read-only)", url: url, authMode: .token)
    plain.secret = token
    let readOnly = GatewayStore(profile: plain)
    readOnly.start()
    if await waitFor("read-only connection", { readOnly.state.isConnected && readOnly.hello != nil }) {
        await readOnly.settings.load()
        check(!readOnly.settings.canEdit, "no admin scope → no edit")
        let error = await readOnly.settings.saveReactionLevel(channel: "whatsapp", account: nil, level: .off)
        check(error != nil, "saving without operator.admin is refused (\(error ?? "nil"))")
        readOnly.stop()
    }
}
