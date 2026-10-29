import Foundation
@testable import PincerKit

// The header's thinking-level picker (#1086): offline model, the built-in demo and the mock Gateway.

@MainActor
func runThinkingLevelChecks() {
    check(["high", "xhigh", "max", "ultra", " ULTRA "].allSatisfy { ThinkingLevel.isExpensive($0) }, "slow, costly levels are expensive")
    check(!["adaptive", "medium", "low", "off", ""].contains { ThinkingLevel.isExpensive($0) } && !ThinkingLevel.isExpensive(nil),
          "adaptive, cheaper levels and no level aren't")
    check(ThinkingLevel.label(for: "max", in: [SlashCommandChoice(value: "max", label: "Turbo")]) == "Turbo"
          && ThinkingLevel.label(for: "xhigh", in: nil) == "Extra High" && ThinkingLevel.label(for: "ultra", in: []) == "Ultra",
          "labels: the Gateway's, else a canonical one")
    check(ThinkingLevel.canonicalLabel(for: "xhigh") == "Extra High" && ThinkingLevel.canonicalLabel(for: "galaxy") == nil
          && ThinkingLevel.label(for: "xhigh", in: [SlashCommandChoice(value: "xhigh", label: "xhigh")]) == "Extra High",
          "canonical labels replace a Gateway label that's just the id")

    let levels = #"[{"id":"off","label":"Off"},{"id":"medium","label":"Medium"},{"id":"high","label":"High"},{"id":"ultra","label":"Ultra"}]"#
    guard let row = SessionRow(json(#"{"key":"k","thinkingLevels":\#(levels),"thinkingDefault":"medium","label":"x"}"#)) else {
        check(false, "thinking-level row parses"); return
    }
    let follows = ThinkingLevelMenu(row: row)
    check(follows.followsDefault && follows.defaultLabel == "Medium" && follows.items.map(\.id) == ["off", "medium", "high", "ultra"]
          && !follows.items.contains(where: \.isSelected) && !follows.currentIsExpensive, "no override: follows the default, nothing checked")
    let ultra = row.settingThinkingLevel("Ultra")
    let picked = ThinkingLevelMenu(row: ultra)
    check(!picked.followsDefault && picked.items.filter(\.isSelected).map(\.id) == ["ultra"] && picked.currentIsExpensive,
          "an override checks its item and warns")
    check(ThinkingLevel.expensiveWarning(for: ultra) == "Ultra thinking, may be slower and cost more"
          && ThinkingLevel.expensiveWarning(for: row) == nil, "compact Chat Options warning only for expensive levels")
    check(ultra.raw["label"] == "x" && ultra.settingThinkingLevel(nil).thinkingLevel == nil
          && ultra.settingThinkingLevel(nil).effectiveThinkingLevel == "medium", "settingThinkingLevel sets, clears and keeps other fields")
    let unlisted = ThinkingLevelMenu(row: row.settingThinkingLevel("xhigh"))
    check(unlisted.items.last.map { $0.id == "xhigh" && $0.isSelected && !$0.isEnabled && $0.label == "Extra High" } == true,
          "an unlisted current level is appended, checked and disabled")
    let legacy = SessionRow(json(#"{"key":"k","thinkingOptions":["Low","High"]}"#)).map(ThinkingLevelMenu.init(row:))
    check(legacy?.reportsLevels == true && legacy?.items.map(\.id) == ["low", "high"], "legacy thinkingOptions")
    let bare = SessionRow(json(#"{"key":"k"}"#)).map(ThinkingLevelMenu.init(row:))
    check(bare?.reportsLevels == false && bare?.items.isEmpty == true && bare?.currentLabel == nil, "no levels reported")
}

@MainActor
private func checkThinkingLevelRoundTrip(_ gateway: GatewayStore, label: String) async {
    let main = "agent:main:main", papers = "agent:research:dashboard:papers"
    func history(_ key: String) async -> String? {
        try? await gateway.connection.request("chat.history", ["sessionKey": .string(key), "limit": 1])["thinkingLevel"]?.text
    }
    check(gateway.sessions[papers]?.thinkingLevel == "ultra" && ThinkingLevelMenu(row: gateway.sessions[papers]!).currentIsExpensive,
          "\(label): Paper digest is seeded on Ultra and warns")
    let papersHistory = await history(papers)
    check(papersHistory == "ultra", "\(label): chat.history reports the session's level")
    check(gateway.sessions[main]?.thinkingLevel == nil && gateway.sessions[main]?.thinkingDefault == "medium"
          && gateway.sessions[main]?.thinkingLevelChoices?.count == 9, "\(label): main follows its default, nine levels offered")

    await gateway.setThinkingLevel(main, to: "high")
    check(gateway.sessions[main]?.thinkingLevel == "high" && gateway.lastError == nil, "\(label): set High")
    let highHistory = await history(main)
    check(highHistory == "high", "\(label): chat.history follows the row")
    await gateway.refreshSessions()
    check(gateway.sessions[main]?.thinkingLevel == "high", "\(label): the Gateway kept High")

    await gateway.setThinkingLevel(main, to: "galaxy-brain")
    check(gateway.sessions[main]?.thinkingLevel == "high" && gateway.lastError?.isEmpty == false,
          "\(label): an unlisted level is rejected and rolled back")
    gateway.lastError = nil

    await gateway.setThinkingLevel(main, to: nil)
    check(gateway.sessions[main]?.thinkingLevel == nil && gateway.sessions[main]?.effectiveThinkingLevel == "medium",
          "\(label): reset follows the default again")
    await gateway.refreshSessions()
    check(gateway.sessions[main]?.thinkingLevel == nil && gateway.lastError == nil, "\(label): null cleared the override")
    let defaultHistory = await history(main)
    check(defaultHistory == "medium", "\(label): chat.history falls back to the default")

    // A change made elsewhere (another client) arrives via sessions.changed.
    _ = try? await gateway.connection.request("sessions.patch", ["key": .string(papers), "thinkingLevel": "low"])
    let broadcast = await waitFor("\(label) thinking level broadcast") { gateway.sessions[papers]?.thinkingLevel == "low" }
    check(broadcast, "\(label): sessions.changed carries the new level")
    _ = try? await gateway.connection.request("sessions.patch", ["key": .string(papers), "thinkingLevel": "ultra"])
    _ = await waitFor("\(label) thinking level restored") { gateway.sessions[papers]?.thinkingLevel == "ultra" }
}

@MainActor
func runDemoThinkingLevelChecks() async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let gateway = GatewayStore(profile: .demo(), defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    defer { gateway.stop() }
    gateway.start(); gateway.reconnectIfNeeded()
    let connected = await waitFor("thinking level demo", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "thinking level checks connect to the demo")
    guard connected else { return }
    let forge = gateway.sessions["agent:coder:main"]
    check(forge?.thinkingLevel == nil && forge?.effectiveThinkingLevel == "high"
          && forge.map { ThinkingLevelMenu(row: $0) }.map { $0.followsDefault && $0.defaultLabel == "High" && $0.currentIsExpensive } == true,
          "demo: Forge's main chat inherits High and warns")
    await checkThinkingLevelRoundTrip(gateway, label: "demo")
}

@MainActor
func runLiveThinkingLevelChecks(url: String, token: String) async {
    let (defaults, suite) = scratchDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = GatewayProfile(name: "Thinking level check", url: url, authMode: .token)
    profile.secret = token
    let gateway = GatewayStore(profile: profile, defaults: defaults)
    gateway.cacheRoot = nil; gateway.outboxRoot = nil; gateway.notifier = nil
    gateway.start()
    defer { gateway.stop(); profile.forgetCredentials() }
    let connected = await waitFor("thinking level live", timeout: 25) { gateway.state.isConnected && gateway.bootstrapped }
    check(connected, "thinking level checks connect to the mock")
    guard connected, gateway.sessions["agent:research:dashboard:papers"] != nil else {
        check(false, "mock lists Paper digest"); return
    }
    await checkThinkingLevelRoundTrip(gateway, label: "mock")
}
