import Foundation
import PincerKit

// Command Policy (exec.approvals.get/set): unit checks, the built-in demo and a live mock Gateway.

private let policySnapshotJSON = #"""
{"path":"~/.openclaw/exec-approvals.json","exists":true,"hash":"h1",
 "file":{"version":1,"socket":{"path":"~/.openclaw/exec-approvals.sock"},"futureKey":{"keep":true},
  "defaults":{"security":"allowlist","ask":"on-miss"},
  "agents":{
   "*":{"ask":"always"},
   "main":{"security":"deny","autoAllowSkills":true,"futureAgentKey":1,
    "allowlist":[
     {"id":"e1","pattern":"/usr/bin/git","source":"allow-always","commandText":"git status","argPattern":"^status$",
      "lastUsedAt":1700000000000,"lastUsedCommand":"git status --short","lastResolvedPath":"/usr/bin/git"},
     {"pattern":"/bin/ls"},
     {"id":"e3","pattern":"/usr/bin/make","lastUsedAt":1700000500000}],
    "mcpTools":[{"server":"github","tool":"create_issue","source":"allow-always","addedAt":1690000000000,"lastUsedAt":1700000100000}]},
   "research":{"ask":"on-request"},
   "ghost":{"allowlist":[{"id":"g1","pattern":"/usr/bin/curl","lastUsedAt":1600000000000}]}}},
 "resolvedDefaults":{"security":"allowlist","ask":"on-miss","askFallback":"deny","autoAllowSkills":false}}
"""#

/// A scripted Gateway with the mock's hash and error rules, for `ExecPolicyModel`.
@MainActor
private final class ScriptedPolicyGateway {
    var file: JSONValue
    var exists: Bool
    var revision = 1
    var calls: [(String, JSONValue)] = []
    /// Thrown by the next set instead of the normal handling.
    var nextSetError: GatewayError?
    var getError: GatewayError?

    init(_ snapshot: JSONValue) {
        self.file = snapshot["file"] ?? ["version": 1]
        self.exists = snapshot["exists"]?.bool ?? true
    }

    var hash: String { "h\(self.revision)" }

    func snapshot() -> JSONValue {
        var file = self.file.object ?? [:]
        if var socket = file["socket"]?.object {
            socket["token"] = nil
            file["socket"] = .object(socket)
        }
        return ["path": "~/.openclaw/exec-approvals.json", "exists": .bool(self.exists), "hash": .string(self.hash),
                "file": .object(file),
                "resolvedDefaults": ["security": "allowlist", "ask": "on-miss", "askFallback": "deny", "autoAllowSkills": false]]
    }

    /// Someone else saved the file.
    func touch() { self.revision += 1 }

    func handle(_ method: String, _ params: JSONValue) throws -> JSONValue {
        self.calls.append((method, params))
        switch method {
        case ExecPolicy.getMethod:
            if let getError { throw getError }
            return self.snapshot()
        case ExecPolicy.setMethod:
            if let error = self.nextSetError {
                self.nextSetError = nil
                throw error
            }
            let base = params["baseHash"]?.string
            if self.exists, base == nil {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "exec approvals base hash required; re-run exec.approvals.get and retry", details: nil)
            }
            if let base, base != self.hash {
                throw GatewayError.rpc(code: "INVALID_REQUEST", message: "exec approvals changed since last load; re-run exec.approvals.get and retry", details: nil)
            }
            self.file = params["file"] ?? ["version": 1]
            self.exists = true
            self.revision += 1
            return self.snapshot()
        default:
            throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil)
        }
    }

    var setCalls: [JSONValue] { self.calls.filter { $0.0 == ExecPolicy.setMethod }.map(\.1) }
    var getCount: Int { self.calls.filter { $0.0 == ExecPolicy.getMethod }.count }
}

private func jsonText(_ value: JSONValue?) -> String {
    guard let value, let data = try? JSONEncoder().encode(value) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

private func rpc(_ code: String, _ message: String, _ details: JSONValue? = nil) -> GatewayError {
    .rpc(code: code, message: message, details: details)
}

@MainActor
func checkExecPolicy() async {
    print("Command policy")
    let snapshot = ExecApprovalsSnapshot(json(policySnapshotJSON))
    let file = snapshot.file

    // Decoding.
    check(snapshot.path == "~/.openclaw/exec-approvals.json" && snapshot.exists && snapshot.hash == "h1", "snapshot path, exists, hash")
    check(snapshot.resolvedDefaults?[.askFallback] == "deny" && snapshot.resolvedDefaults?[.autoAllowSkills] == false,
          "resolvedDefaults decoded")
    check(ExecApprovalsSnapshot(json(#"{"path":"p","exists":false,"hash":"x","file":{"version":1}}"#)).resolvedDefaults == nil,
          "missing resolvedDefaults → nil")
    check(!ExecApprovalsSnapshot(json(#"{"path":"p","exists":false,"hash":"x","file":{"version":1}}"#)).exists, "exists:false decoded")
    check(file.defaults[.security] == "allowlist" && file.defaults[.ask] == "on-miss" && file.defaults[.askFallback] == nil,
          "defaults decoded, unset fields nil")
    check(Set(file.agentIds) == ["*", "main", "research", "ghost"], "agent keys incl. * (\(file.agentIds.sorted()))")
    check(file.overrides("*")[.ask] == "always" && file.overrides("main")[.autoAllowSkills] == true, "agent overrides decoded")
    check(file.overrides("research")[.ask] == "on-request", "unknown enum value kept")
    let git = file.allowlist("main").first
    check(git?.entryId == "e1" && git?.pattern == "/usr/bin/git" && git?.isAllowAlways == true && git?.commandText == "git status"
          && git?.argPattern == "^status$" && git?.lastUsedCommand == "git status --short" && git?.lastResolvedPath == "/usr/bin/git"
          && git?.lastUsedAt == Date(timeIntervalSince1970: 1_700_000_000), "allowlist entry: every field, lastUsedAt in ms")
    check(file.allowlist("main")[1].entryId == nil && !file.allowlist("main")[1].isAllowAlways && file.allowlist("main")[1].index == 1,
          "hand-added entry: no id, no source")
    let tool = file.mcpTools("main").first
    check(tool?.title == "github › create_issue" && tool?.addedAt == Date(timeIntervalSince1970: 1_690_000_000)
          && tool?.lastUsedAt == Date(timeIntervalSince1970: 1_700_000_100), "mcpTools grant decoded")
    check(ExecPolicyField.ask.label(for: "on-request") == "On request" && ExecPolicyField.ask.rank("on-request") == nil,
          "unknown value humanized, unranked")
    check(ExecPolicyField.security.label(for: "full") == "Allow any command" && ExecPolicyField.askFallback.label(for: "full") == "Run anyway"
          && ExecPolicyField.ask.label(for: "on-miss") == "When not on the allowlist", "known labels")
    check(ExecPolicyField.allCases.map(\.label) == ["Commands", "Ask for approval", "If no one answers", "Trust skill commands"],
          "field labels")
    check(ExecApprovalsFile(nil).raw == ["version": 1] && ExecApprovalsFile(json(#""x""#)).raw == ["version": 1], "missing file → version 1")

    // Mode projection (D1).
    let modes: [(JSONValue?, JSONValue?, ExecPolicyMode)] = [
        ("deny", "always", .deny), ("deny", nil, .deny), ("allowlist", "off", .allowlist), ("full", "off", .full),
        ("full", "on-miss", .full), ("full", "always", .ask), ("allowlist", "on-miss", .ask), ("allowlist", "always", .ask),
        (nil, nil, .ask), ("weird", "off", .ask),
    ]
    check(modes.allSatisfy { ExecPolicyMode(security: $0.0, ask: $0.1) == $0.2 }, "mode projection like resolveExecModeFromPolicy")
    check(ExecPolicyMode.deny.summary == "Commands are blocked" && ExecPolicyMode.allowlist.summary == "Allowlist only, never asks"
          && ExecPolicyMode.full.summary == "Any command runs" && ExecPolicyMode.ask.summary == "Asks before running unlisted commands",
          "mode summaries")

    // Loosening (C1).
    let resolved = snapshot.resolvedDefaults
    let names = ["main": "Scout"]
    func loosening(_ change: (inout ExecApprovalsFile) -> Void, from base: ExecApprovalsFile = file) -> [String] {
        var draft = base
        change(&draft)
        return ExecPolicy.looseningChanges(from: base, to: draft, resolvedDefaults: resolved, agentNames: names)
    }
    check(loosening { $0.set(.security, "full", agent: "main") } == ["Scout: Commands → Allow any command"], "agent override loosened")
    check(loosening { $0.set(.ask, "off", agent: "*") } == ["All agents: Ask for approval → Never"], "wildcard agent named All agents")
    check(loosening { $0.set(.security, "full", agent: nil) } == ["Defaults: Commands → Allow any command"],
          "default loosened: listed once under Defaults (\(loosening { $0.set(.security, "full", agent: nil) }))")
    check(loosening { $0.set(.autoAllowSkills, true, agent: nil) } == ["Defaults: Trust skill commands → On"],
          "unset default loosened against resolvedDefaults")
    check(loosening { $0.set(.security, nil, agent: "main") } == ["Scout: Commands → Only allowlisted"],
          "clearing a tighter override inherits a looser default")
    check(loosening { $0.set(.autoAllowSkills, nil, agent: "main") }.isEmpty, "clearing a looser override is tightening")
    check(loosening { $0.set(.security, "yolo", agent: "main") } == ["Scout: Commands → Yolo"], "unknown new value counts as loosening")
    check(loosening { $0.set(.askFallback, "full", agent: "coder") } == ["coder: If no one answers → Run anyway"],
          "first override for an agent not in the file")
    check(loosening { $0.set(.ask, "always", agent: nil); $0.set(.security, "deny", agent: nil); $0.set(.ask, "always", agent: "research") }.isEmpty,
          "tightening changes need no confirmation")
    check(loosening { $0.removeAllowlistEntry(agent: "main", at: 0); $0.removeMcpTool(agent: "main", at: 0) }.isEmpty,
          "removals need no confirmation")
    check(loosening { $0.clearOverrides(agent: "*") }.isEmpty == false, "Use Defaults on a stricter agent loosens it")
    check(loosening { $0.set(.ask, "off", agent: nil) }.contains("Defaults: Ask for approval → Never"), "ask toward off loosens")

    // Loosening from an unknown or missing old value (B1).
    check(ExecPolicyField.security.isLoosening(from: nil, to: "full") && ExecPolicyField.security.isLoosening(from: "weird", to: "full")
          && ExecPolicyField.ask.isLoosening(from: nil, to: "off") && ExecPolicyField.askFallback.isLoosening(from: "weird", to: "full")
          && ExecPolicyField.autoAllowSkills.isLoosening(from: nil, to: true), "unknown/missing old → loosest counts as loosening")
    check(!ExecPolicyField.security.isLoosening(from: nil, to: "allowlist") && !ExecPolicyField.security.isLoosening(from: "weird", to: "deny")
          && !ExecPolicyField.ask.isLoosening(from: nil, to: "on-miss") && !ExecPolicyField.autoAllowSkills.isLoosening(from: nil, to: false),
          "unknown/missing old → a non-loosest known value doesn't")
    check(ExecPolicyField.security.isLoosening(from: nil, to: "yolo") && ExecPolicyField.security.isLoosening(from: "weird", to: "yolo")
          && !ExecPolicyField.security.isLoosening(from: "weird", to: "weird") && !ExecPolicyField.security.isLoosening(from: nil, to: nil),
          "unknown new counts; unchanged doesn't")
    check(ExecPolicyField.security.isLoosening(from: "full", to: nil), "clearing to no value counts as loosening")
    let bare = ExecApprovalsFile(json(#"{"version":1}"#))
    func bareLoosening(_ change: (inout ExecApprovalsFile) -> Void) -> [String] {
        var draft = bare
        change(&draft)
        return ExecPolicy.looseningChanges(from: bare, to: draft, resolvedDefaults: nil, agentNames: names)
    }
    check(bareLoosening { $0.set(.security, "full", agent: nil) } == ["Defaults: Commands → Allow any command"],
          "no defaults and no resolvedDefaults: Allow any command asks first")
    check(bareLoosening { $0.set(.autoAllowSkills, true, agent: "main") } == ["Scout: Trust skill commands → On"],
          "no resolvedDefaults: agent trusting skills asks first")
    check(bareLoosening { $0.set(.security, "allowlist", agent: nil); $0.set(.ask, "always", agent: "main") }.isEmpty,
          "no resolvedDefaults: middle/safe values don't ask")
    let unknownSaved = ExecApprovalsFile(json(#"{"version":1,"defaults":{"security":"future-mode"}}"#))
    var unknownDraft = unknownSaved
    unknownDraft.set(.security, "full", agent: nil)
    check(ExecPolicy.looseningChanges(from: unknownSaved, to: unknownDraft, resolvedDefaults: resolved) == ["Defaults: Commands → Allow any command"],
          "unknown saved value → Allow any command asks first")

    // `*` inheritance: agent → `*` → defaults → Gateway default.
    check(ExecPolicy.effectiveValue(.ask, agent: "main", in: file, saved: file, resolvedDefaults: resolved) == "always"
          && ExecPolicy.effectiveValue(.ask, agent: "ghost", in: file, saved: file, resolvedDefaults: resolved) == "always"
          && ExecPolicy.effectiveValue(.ask, agent: "coder", in: file, saved: file, resolvedDefaults: resolved) == "always",
          "agents without an ask override inherit * (even ones not in the file)")
    check(ExecPolicy.effectiveValue(.ask, agent: "research", in: file, saved: file, resolvedDefaults: resolved) == "on-request",
          "an agent's own override beats *")
    check(ExecPolicy.inheritedValue(.ask, agent: "*", in: file, saved: file, resolvedDefaults: resolved) == "on-miss"
          && ExecPolicy.effectiveValue(.ask, agent: "*", in: file, saved: file, resolvedDefaults: resolved) == "always"
          && ExecPolicy.wildcardValue(.ask, agent: "*", in: file) == nil, "* itself inherits the defaults")
    check(ExecPolicy.inheritedValue(.security, agent: "ghost", in: file, saved: file, resolvedDefaults: resolved) == "allowlist"
          && ExecPolicy.wildcardValue(.security, agent: "ghost", in: file) == nil
          && ExecPolicy.inheritedValue(.askFallback, agent: "ghost", in: file, saved: file, resolvedDefaults: resolved) == "deny",
          "fields * doesn't set fall through to defaults, then the Gateway default")
    check(loosening { $0.set(.ask, "off", agent: "main") } == ["Scout: Ask for approval → Never"],
          "an override looser than the inherited * value asks first")
    check(loosening { $0.set(.ask, "always", agent: "main") }.isEmpty, "an override equal to the inherited * value doesn't")
    check(loosening { $0.set(.ask, nil, agent: "*") } == ["All agents: Ask for approval → When not on the allowlist"],
          "clearing * is listed once under All agents, not per inheriting agent (\(loosening { $0.set(.ask, nil, agent: "*") }))")
    check(loosening { $0.set(.security, "full", agent: "*") } == ["All agents: Commands → Allow any command"],
          "loosening * listed once")
    check(loosening { $0.set(.ask, "off", agent: nil) } == ["Defaults: Ask for approval → Never"],
          "a looser default hidden by * for every agent is listed under Defaults only")

    // The file sent by save (S3).
    var edited = file
    edited.set(.ask, "always", agent: "main")
    let params = ExecPolicy.setParams(draft: edited, snapshot: snapshot)
    let sent = params["file"]
    check(params["baseHash"] == "h1", "baseHash from the snapshot")
    check(sent?["agents"]?["main"]?["ask"] == "always", "edit applied")
    var expected = file.raw.object ?? [:]
    var mainAgent = expected["agents"]?["main"]?.object ?? [:]
    mainAgent["ask"] = "always"
    var agentsObject = expected["agents"]?.object ?? [:]
    agentsObject["main"] = .object(mainAgent)
    expected["agents"] = .object(agentsObject)
    check(sent == .object(expected), "only the edited key changes; unknown keys, entry ids and fields survive")
    check(sent?["futureKey"] == ["keep": true] && sent?["agents"]?["main"]?["futureAgentKey"] == 1
          && sent?["agents"]?["main"]?["allowlist"]?[0]?["lastResolvedPath"] == "/usr/bin/git", "unknown fields preserved")
    let leaky = ExecApprovalsSnapshot(json(#"{"path":"p","exists":true,"hash":"h","file":{"version":1,"socket":{"path":"/s","token":"secret"}}}"#))
    var leakyDraft = leaky.file
    leakyDraft.set(.ask, "always", agent: nil)
    let leakySent = ExecPolicy.setParams(draft: leakyDraft, snapshot: leaky)["file"]
    check(leakySent?["socket"] == ["path": "/s"] && !jsonText(leakySent).contains("secret"), "socket.token never sent")
    let tokenOnly = ExecApprovalsSnapshot(json(#"{"path":"p","exists":true,"hash":"h","file":{"version":1,"socket":{"token":"secret"}}}"#))
    check(ExecPolicy.setParams(draft: tokenOnly.file, snapshot: tokenOnly)["file"]?["socket"] == nil, "token-only socket left out")
    check(ExecPolicy.setParams(draft: edited, snapshot: snapshot)["file"]?["version"] == 1, "version stays 1")
    let missing = ExecApprovalsSnapshot(json(#"{"path":"p","exists":false,"hash":"empty","file":{"version":1}}"#))
    var created = missing.file
    created.set(.security, "deny", agent: nil)
    let createParams = ExecPolicy.setParams(draft: created, snapshot: missing)
    check(createParams["baseHash"] == "empty" && createParams["file"] == ["version": 1, "defaults": ["security": "deny"]],
          "exists:false still sends baseHash")
    var pruned = file
    pruned.set(.security, "deny", agent: "coder")
    pruned.set(.security, nil, agent: "coder")
    check(ExecPolicy.outgoingFile(pruned, base: file)["agents"]?["coder"] == nil, "agent left empty by edits is pruned")
    check(!ExecPolicy.hasChanges(pruned, comparedTo: file), "set then cleared → no changes")
    var wildcardCleared = file
    wildcardCleared.clearOverrides(agent: "*")
    check(ExecPolicy.outgoingFile(wildcardCleared, base: file)["agents"]?["*"] == nil, "agent with no keys left is removed on save")
    var useDefaults = file
    useDefaults.clearOverrides(agent: "main")
    let mainAfter = ExecPolicy.outgoingFile(useDefaults, base: file)["agents"]?["main"]
    check(mainAfter?["security"] == nil && mainAfter?["autoAllowSkills"] == nil && mainAfter?["allowlist"]?.array?.count == 3
          && mainAfter?["mcpTools"]?.array?.count == 1 && mainAfter?["futureAgentKey"] == 1, "Use Defaults keeps allowlist, tools, unknown keys")
    var removed = file
    removed.removeAllowlistEntry(agent: "main", at: 1)
    check(removed.allowlist("main").map(\.entryId) == ["e1", "e3"], "remove the entry at its index")
    var unsetDefault = file
    unsetDefault.set(.askFallback, "full", agent: nil)
    unsetDefault.set(.askFallback, nil, agent: nil)
    check(!ExecPolicy.hasChanges(unsetDefault, comparedTo: file) && ExecPolicy.outgoingFile(unsetDefault, base: file)["defaults"]?["askFallback"] == nil,
          "Gateway default removes the key instead of writing the resolved value")

    // Effective values (D2, A3).
    check(ExecPolicy.gatewayDefault(.askFallback, saved: file, resolvedDefaults: resolved) == "deny"
          && ExecPolicy.gatewayDefault(.security, saved: file, resolvedDefaults: resolved) == nil, "Gateway default only for unset fields")
    check(ExecPolicy.effectiveValue(.security, agent: "main", in: file, saved: file, resolvedDefaults: resolved) == "deny"
          && ExecPolicy.effectiveValue(.security, agent: "ghost", in: file, saved: file, resolvedDefaults: resolved) == "allowlist"
          && ExecPolicy.effectiveValue(.askFallback, agent: "ghost", in: file, saved: file, resolvedDefaults: resolved) == "deny",
          "agent value, else default, else resolved default")

    // Error mapping.
    check(ExecPolicyError.classify(rpc("FORBIDDEN", "missing scope: operator.admin", ["code": "MISSING_SCOPE", "scope": "operator.admin"])) == .needsAdmin,
          "FORBIDDEN MISSING_SCOPE → needs admin")
    check(ExecPolicyError.classify(rpc("MISSING_SCOPE", "nope")) == .needsAdmin, "MISSING_SCOPE code → needs admin")
    check(ExecPolicyError.classify(rpc("UNKNOWN_METHOD", "unknown method: exec.approvals.get")) == .unsupported, "unknown method → unsupported")
    check(ExecPolicyError.classify(rpc("INVALID_REQUEST", "exec approvals changed since last load; re-run exec.approvals.get and retry")) == .conflict
          && ExecPolicyError.classify(rpc("INVALID_REQUEST", "exec approvals base hash required; re-run exec.approvals.get and retry")) == .conflict,
          "changed since last load / base hash required → conflict")
    check(ExecPolicyError.classify(rpc("INVALID_REQUEST", "invalid exec.approvals.set params: x")) == .validation("invalid exec.approvals.set params: x"),
          "other INVALID_REQUEST → validation")
    check(ExecPolicyError.classify(rpc("UNAVAILABLE", "disk full")) == .other("disk full"), "other codes → other")

    // Agents list (A1, A2, A5).
    let known = [AgentSummary(id: "main", name: "Scout", emoji: "🔭"), AgentSummary(id: "coder", name: "Forge"),
                 AgentSummary(id: "research", name: "Atlas")]
    let rows = ExecPolicy.agentRows(file: file, agents: known)
    check(rows.map(\.id) == ["*", "research", "coder", "ghost", "main"], "wildcard first, then by display name (\(rows.map(\.id)))")
    check(rows[0].name == "All agents" && rows[0].isWildcard && rows[0].isCurrentAgent, "* is All agents")
    let ghostRow = rows.first { $0.id == "ghost" }
    check(ghostRow?.name == "ghost" && ghostRow?.isCurrentAgent == false && ghostRow?.inFile == true, "unknown agent labeled by id, not current")
    let coderRow = rows.first { $0.id == "coder" }
    check(coderRow?.inFile == false && coderRow?.summary == "Uses defaults" && coderRow?.badgeCount == 0, "agent only in agents.list")
    let mainRow = rows.first { $0.id == "main" }
    check(mainRow?.title == "🔭 Scout" && mainRow?.badgeCount == 4
          && mainRow?.summary == "Blocks all commands · Trusts skill commands · 3 allowed commands · 1 allowed tool",
          "row summary and badge (\(mainRow?.summary ?? ""))")
    check(ExecPolicy.agentSummary("research", in: file) == "Ask for approval: On request", "unknown override phrase humanized")
    let recent = ExecPolicy.recentlyAllowed(file)
    check(recent.map(\.entry.entryId) == ["e3", "e1", "g1"] && recent.first?.agentId == "main", "recently allowed, newest first, across agents")

    // Search (P3).
    for query in ["command policy", "exec", "allowlist", "always allow", "approval policy", "ask", "security", "Command"] {
        check(SettingsCatalog.destinations(matching: query).first?.destination == .execPolicy, "search \"\(query)\" → Command Policy")
    }
    check(SettingsCatalog.destinations(matching: "audit").allSatisfy { $0.destination != .execPolicy }
          && SettingsCatalog.destinations(matching: "").isEmpty, "unrelated and empty queries")

    await checkExecPolicyModel()
}

@MainActor
private func checkExecPolicyModel() async {
    // Load, edit, confirm loosening, save.
    let gateway = ScriptedPolicyGateway(json(policySnapshotJSON))
    let model = ExecPolicyModel { method, params in try gateway.handle(method, params) }
    check(!model.hasLoaded && model.snapshot == nil, "nothing loaded before the page opens")
    await model.loadIfNeeded()
    check(model.hasLoaded && model.supported && !model.needsAdmin && model.snapshot?.hash == "h1" && !model.hasChanges && model.canWrite,
          "model loads the snapshot")
    check(model.defaultsMode == .ask && model.mode(agent: "main") == .deny, "model modes")
    model.set(.security, "full", agent: "main")
    check(model.hasChanges, "edit makes the draft dirty")
    await model.load()
    check(gateway.getCount == 1 && model.value(.security, agent: "main") == "full", "load with a draft does nothing")
    let first = await model.save(agentNames: ["main": "Scout"])
    check(first == .needsConfirmation(["Scout: Commands → Allow any command"]) && gateway.setCalls.isEmpty
          && model.pendingLoosening == ["Scout: Commands → Allow any command"], "loosening asks first, nothing sent")
    let saved = await model.save(allowLoosening: true, agentNames: ["main": "Scout"])
    check(saved == .saved && gateway.setCalls.count == 1 && gateway.setCalls[0]["baseHash"] == "h1" && gateway.getCount == 1,
          "Save Anyway sends set with baseHash, no extra get")
    check(model.snapshot?.hash == "h2" && !model.hasChanges && model.lastSave != nil && model.pendingLoosening == nil,
          "snapshot and hash replaced from the response, draft cleared")
    model.removeAllowlistEntry(agent: "main", at: 0)
    let removal = await model.save()
    check(removal == .saved && gateway.file["agents"]?["main"]?["allowlist"]?.array?.count == 2, "removal saves without asking")
    let saveResult1 = await model.save()
    check(saveResult1 == .noChanges, "nothing to save")
    model.set(.ask, "always", agent: nil)
    model.revert()
    check(!model.hasChanges, "Revert drops the draft")

    // Conflict: reload and discard the draft (T5).
    model.set(.ask, "always", agent: "research")
    gateway.touch()
    let conflict = await model.save()
    check(conflict == .conflict && model.banner == .conflict && !model.hasChanges && model.snapshot?.hash == gateway.hash,
          "stale hash → reloaded, draft discarded, conflict banner")
    model.set(.ask, "always", agent: "research")
    check(model.banner == nil, "the next edit clears the conflict banner")
    gateway.nextSetError = rpc("INVALID_REQUEST", "exec approvals base hash required; re-run exec.approvals.get and retry")
    let saveResult2 = await model.save()
    check(saveResult2 == .conflict && !model.hasChanges, "base hash required → conflict path")

    // Validation and other errors keep the draft (T4, T8).
    model.set(.ask, "always", agent: "research")
    gateway.nextSetError = rpc("INVALID_REQUEST", "invalid exec.approvals.set params: file/agents/x: bad")
    let rejected = await model.save()
    check(rejected == .failed(.validation("invalid exec.approvals.set params: file/agents/x: bad"))
          && model.banner == .rejected("invalid exec.approvals.set params: file/agents/x: bad") && model.hasChanges,
          "INVALID_REQUEST → inline error, draft kept")
    check(model.banner?.message == "The Gateway rejected the change: invalid exec.approvals.set params: file/agents/x: bad", "rejected banner text")
    gateway.nextSetError = rpc("UNAVAILABLE", "gateway busy")
    let saveResult3 = await model.save()
    check(saveResult3 == .failed(.other("gateway busy")) && model.banner == .failed("gateway busy", retrySave: true) && model.hasChanges,
          "other errors → banner with retry, draft kept")
    let saveResult4 = await model.save()
    check(saveResult4 == .saved && !model.hasChanges && model.banner == nil, "retry saves")

    // Needs admin (T2).
    let noAdmin = ExecPolicyModel(scopes: { ["operator.read", "operator.approvals"] }) { _, _ in
        throw rpc("FORBIDDEN", "missing scope: operator.admin", ["code": "MISSING_SCOPE", "scope": "operator.admin"])
    }
    await noAdmin.loadIfNeeded()
    check(noAdmin.needsAdmin && noAdmin.hasLoaded && noAdmin.snapshot == nil && noAdmin.supported, "MISSING_SCOPE → needs admin")
    check(ExecPolicy.needsAdminMessage.hasPrefix("Viewing and changing the command policy needs Full Management"), "needs-admin copy")
    // A looser Gateway that answers get without admin: read-only.
    let looser = ScriptedPolicyGateway(json(policySnapshotJSON))
    let readOnly = ExecPolicyModel(scopes: { ["operator.read"] }) { method, params in try looser.handle(method, params) }
    await readOnly.load()
    readOnly.set(.ask, "always", agent: nil)
    check(readOnly.snapshot != nil && !readOnly.canWrite, "get without admin → read-only")
    let saveResult5 = await readOnly.save()
    check(saveResult5 == .failed(.needsAdmin) && looser.setCalls.isEmpty, "read-only never sends set")
    check(readOnly.readOnlyReason?.hasPrefix("This device can view the command policy but not change it") == true
          && readOnly.banner == .notice(readOnly.readOnlyReason ?? ""), "read-only save → notice banner with the reason")
    check(readOnly.savedValue(.ask, agent: nil) == "on-miss" && readOnly.value(.ask, agent: nil) == "always", "savedValue vs draft value")
    let demoLike = ExecPolicyModel(scopes: { [] }, allowsWritesWithoutAdmin: true) { method, params in try looser.handle(method, params) }
    await demoLike.load()
    check(demoLike.canWrite, "the demo may write without admin")

    // Unsupported (T3).
    var legacyCalled = false
    let legacy = ExecPolicyModel(methods: { ["chat.send", "exec.approval.resolve"] }) { _, _ in
        legacyCalled = true
        return [:]
    }
    await legacy.loadIfNeeded()
    check(!legacy.supported && legacy.hasLoaded && !legacyCalled, "hello without exec.approvals.get → unsupported, no request")
    let unknown = ExecPolicyModel(methods: { [] }) { method, _ in throw rpc("UNKNOWN_METHOD", "unknown method: \(method)") }
    await unknown.loadIfNeeded()
    check(!unknown.supported && unknown.hasLoaded, "unknown method → unsupported")
    let getOnly = ScriptedPolicyGateway(json(policySnapshotJSON))
    let noSet = ExecPolicyModel(methods: { [ExecPolicy.getMethod] }) { method, params in try getOnly.handle(method, params) }
    await noSet.load()
    check(noSet.supported && noSet.snapshot != nil && !noSet.canWrite, "get without set → read-only")
    check(noSet.readOnlyReason == "This gateway can't change its command policy. Update OpenClaw to manage it here.",
          "get without set → update-OpenClaw reason")
    let setGone = ScriptedPolicyGateway(json(policySnapshotJSON))
    let staleHello = ExecPolicyModel { method, params in try setGone.handle(method, params) }
    await staleHello.load()
    staleHello.set(.ask, "always", agent: nil)
    setGone.nextSetError = rpc("UNKNOWN_METHOD", "unknown method: exec.approvals.set")
    let unknownSet = await staleHello.save()
    check(unknownSet == .failed(.unsupported) && !staleHello.canWrite && staleHello.hasChanges
          && staleHello.banner == .notice("This gateway can't change its command policy. Update OpenClaw to manage it here."),
          "set answered UNKNOWN_METHOD → read-only notice, draft kept")
    let noRetry = await staleHello.save()
    check(noRetry == .failed(.needsAdmin) && setGone.setCalls.count == 1, "no more set after UNKNOWN_METHOD")
    let revoked = ScriptedPolicyGateway(json(policySnapshotJSON))
    let revokedModel = ExecPolicyModel { method, params in try revoked.handle(method, params) }
    await revokedModel.load()
    revokedModel.set(.ask, "always", agent: nil)
    revoked.nextSetError = rpc("FORBIDDEN", "missing scope: operator.admin", ["code": "MISSING_SCOPE", "scope": "operator.admin"])
    let revokedSave = await revokedModel.save()
    check(revokedSave == .failed(.needsAdmin) && revokedModel.banner == .notice(ExecPolicy.needsAdminMessage) && revokedModel.hasChanges,
          "set MISSING_SCOPE → needs-admin notice, draft kept")
    let offline = ScriptedPolicyGateway(json(policySnapshotJSON))
    let offlineModel = ExecPolicyModel { method, params in try offline.handle(method, params) }
    await offlineModel.load()
    offlineModel.set(.ask, "always", agent: nil)
    offline.touch()
    offline.getError = rpc("UNAVAILABLE", "gateway restarting")
    let offlineConflict = await offlineModel.save()
    check(offlineConflict == .conflict && !offlineModel.hasChanges
          && offlineModel.banner == .failed("The command policy changed on the Gateway, so your changes weren't saved, and the latest version couldn't be loaded: gateway restarting", retrySave: false),
          "conflict whose reload fails → failed banner (reload), not conflict")
    let failing = ExecPolicyModel { _, _ in throw rpc("UNAVAILABLE", "policy offline") }
    await failing.load()
    check(failing.loadState.error == "policy offline" && failing.supported && !failing.needsAdmin, "UNAVAILABLE on load → error with Try Again")

    // No file yet (T6).
    let empty = ScriptedPolicyGateway(json(#"{"exists":false,"file":{"version":1}}"#))
    let fresh = ExecPolicyModel { method, params in try empty.handle(method, params) }
    await fresh.load()
    check(fresh.snapshot?.exists == false, "exists:false loaded")
    fresh.set(.security, "deny", agent: nil)
    let saveResult6 = await fresh.save()
    check(saveResult6 == .saved && empty.setCalls.first?["baseHash"] == "h1" && fresh.snapshot?.exists == true,
          "saving creates the file, baseHash sent")

    // A reload in flight doesn't wipe edits made meanwhile (B3).
    let slow = ScriptedPolicyGateway(json(policySnapshotJSON))
    let gate = PolicyGate()
    let racing = ExecPolicyModel { method, params in
        if method == ExecPolicy.getMethod, gate.armed {
            gate.armed = false
            await gate.wait()
        }
        return try slow.handle(method, params)
    }
    await racing.load()
    slow.touch()
    gate.armed = true
    let reload = Task { await racing.load() }
    let paused1 = await gate.waitUntilPaused()
    racing.set(.security, "deny", agent: "ghost")
    gate.open()
    await reload.value
    check(paused1 && racing.value(.security, agent: "ghost") == "deny" && racing.hasChanges && racing.snapshot?.hash == "h1"
          && racing.loadState == .idle && racing.hasLoaded, "edit during a reload is kept with the snapshot it's based on")
    let staleSave = await racing.save()
    check(staleSave == .conflict && racing.snapshot?.hash == "h2", "saving that edit later still hits the stale hash check")
    racing.set(.security, "deny", agent: "ghost")
    gate.armed = true
    let discard = Task { await racing.load(discardingDraft: true) }
    let paused2 = await gate.waitUntilPaused()
    racing.set(.ask, "always", agent: nil)
    gate.open()
    await discard.value
    check(paused2 && !racing.hasChanges && racing.value(.security, agent: "ghost") == nil && racing.value(.ask, agent: nil) == "on-miss",
          "Reload (discarding the draft) replaces edits made in flight")
    gate.armed = true
    let plain = Task { await racing.load() }
    let paused3 = await gate.waitUntilPaused()
    slow.touch()
    gate.open()
    await plain.value
    check(paused3 && racing.snapshot?.hash == slow.hash && !racing.hasChanges, "a reload with no edits in flight applies")
}

/// Holds one request until `open()`.
@MainActor
private final class PolicyGate {
    var armed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async { await withCheckedContinuation { self.continuation = $0 } }

    func open() {
        self.continuation?.resume()
        self.continuation = nil
    }

    func waitUntilPaused() async -> Bool {
        for _ in 0..<1000 {
            if self.continuation != nil { return true }
            await Task.yield()
        }
        return false
    }
}


// MARK: Demo

@MainActor
func runDemoExecPolicy(_ gateway: GatewayStore, chat: ChatStore) async {
    print("Command policy (demo)")
    let policy = gateway.execPolicy
    await policy.loadIfNeeded()
    check(policy.hasLoaded && policy.supported && !policy.needsAdmin && policy.snapshot != nil, "demo exec.approvals.get")
    check(policy.canWrite, "demo page is editable without admin")
    guard let before = policy.snapshot else { return }
    check(!jsonText(before.file.raw).contains("token"), "demo keeps no socket token")
    let rows = policy.agentRows(agents: gateway.agents)
    check(Set(rows.map(\.id)).isSuperset(of: ["main", "research", "coder"]), "demo agents listed (\(rows.map(\.id)))")
    let mainCount = before.file.allowlist("main").count
    policy.removeAllowlistEntry(agent: "main", at: 0)
    let removed = await policy.save()
    check(removed == .saved && policy.snapshot?.hash != before.hash && policy.snapshot?.file.allowlist("main").count == mainCount - 1,
          "demo remove + save → new hash")

    // Always allow in chat, then a save based on the old hash conflicts.
    policy.set(.ask, "always", agent: "coder")
    let hashWithDraft = policy.snapshot?.hash
    let known = Set(gateway.approvals.map(\.id))
    await chat.send("please approve this")
    _ = await waitFor("demo approval") { gateway.approvals.contains { !known.contains($0.id) } }
    guard let approval = gateway.approvals.first(where: { !known.contains($0.id) }) else {
        return check(false, "demo approval surfaced")
    }
    let resolved = await gateway.resolveApproval(approval, decision: "allow-always")
    check(resolved == .resolved, "demo allow-always resolved (\(resolved))")
    try? await Task.sleep(for: .milliseconds(800))
    check(policy.hasChanges && policy.snapshot?.hash == hashWithDraft, "a draft isn't reloaded by exec.approval.resolved")
    let stale = await policy.save()
    check(stale == .conflict && policy.banner == .conflict && !policy.hasChanges, "demo stale save → conflict, draft discarded")
    let appended = policy.snapshot?.file.allowlist("main").last
    check(appended?.isAllowAlways == true && appended?.pattern == "rm -rf ./build", "demo allow-always appended to the agent's allowlist")
    _ = await waitFor("demo approval run", timeout: 20) { !chat.isRunning }

    // Without a draft, a resolution refreshes the page.
    let hash = policy.snapshot?.hash
    let known2 = Set(gateway.approvals.map(\.id))
    await chat.send("please approve this")
    _ = await waitFor("demo approval") { gateway.approvals.contains { !known2.contains($0.id) } }
    if let again = gateway.approvals.first(where: { !known2.contains($0.id) }) {
        await gateway.resolveApproval(again, decision: "allow-always")
        let refreshed = await waitFor("demo policy refresh") { policy.snapshot?.hash != hash }
        check(refreshed, "no draft → reloaded after exec.approval.resolved")
    } else {
        check(false, "second demo approval surfaced")
    }
    _ = await waitFor("demo approval run", timeout: 20) { !chat.isRunning }

    // Unknown values round-trip (D3), and `*` values are inherited.
    await policy.load(discardingDraft: true)
    policy.set(.security, "future-mode", agent: "coder")
    let unknownSave = await policy.save(allowLoosening: true)
    check(unknownSave == .saved && policy.snapshot?.file.overrides("coder")[.security] == "future-mode",
          "demo saves an unknown policy value (\(unknownSave))")
    policy.set(.security, nil, agent: "coder")
    policy.set(.ask, "always", agent: "*")
    let wildcardSave = await policy.save()
    check(wildcardSave == .saved && policy.effectiveValue(.ask, agent: "coder") == "always"
          && policy.inheritsFromWildcard(.ask, agent: "coder"), "demo * value inherited by agents without an override")
    policy.set(.ask, nil, agent: "*")
    _ = await policy.save(allowLoosening: true)
}

// MARK: Live

/// Against the mock: `gateway` has no admin scope, `admin` has Full Management.
@MainActor
func runLiveExecPolicy(profile: GatewayProfile, gateway: GatewayStore, admin: GatewayStore) async {
    print("Command policy (live)")
    let advertised = admin.hello?.methods ?? []
    if !advertised.contains(ExecPolicy.getMethod) {
        // MOCK_NO_EXEC_APPROVALS=1
        await admin.execPolicy.loadIfNeeded()
        check(!admin.execPolicy.supported && admin.execPolicy.hasLoaded, "gateway without exec.approvals.* → unsupported")
        return
    }
    // A connection without Full Management (a fresh store, so earlier reconnects don't matter).
    let readerProfile = GatewayProfile(name: "Policy reader", url: profile.url, authMode: .token)
    readerProfile.secret = profile.secret
    let readerStore = GatewayStore(profile: readerProfile)
    readerStore.start()
    _ = await waitFor("reader connection") { readerStore.state.isConnected && readerStore.hello != nil }
    let reader = readerStore.execPolicy
    await reader.loadIfNeeded()
    check(reader.needsAdmin && reader.snapshot == nil, "without Full Management → needs admin (\(reader.loadState))")
    check(readerStore.hello?.scopes.contains(GatewayConnection.adminScope) == false, "reader has no operator.admin")
    readerStore.stop()

    let policy = admin.execPolicy
    await policy.loadIfNeeded()
    check(policy.hasLoaded && policy.supported && !policy.needsAdmin && policy.canWrite, "admin loads the command policy")
    guard let loaded = policy.snapshot else { return }
    check(loaded.path == "~/.openclaw/exec-approvals.json" && loaded.exists && loaded.resolvedDefaults?[.askFallback] == "deny",
          "mock snapshot path and resolved defaults")
    check(loaded.file.raw["socket"]?["token"] == nil && loaded.file.raw["socket"]?["path"] != nil, "token redacted, path kept")
    let rows = policy.agentRows(agents: admin.agents)
    check(rows.first { $0.id == "ghost" }?.isCurrentAgent == false && rows.contains { $0.id == "coder" && !$0.inFile },
          "ghost agent from the file, coder from agents.list")
    check(policy.defaultsMode == .ask && policy.mode(agent: "research") == .ask, "mock modes")

    // Loosen, confirm, save.
    policy.set(.security, "full", agent: "research")
    let asked = await policy.save()
    if case let .needsConfirmation(changes) = asked {
        check(changes.count == 1 && changes[0].hasSuffix("Commands → Allow any command"), "loosening confirmation (\(changes))")
    } else {
        check(false, "loosening asks first (\(asked))")
    }
    let saved = await policy.save(allowLoosening: true)
    check(saved == .saved && policy.snapshot?.hash != loaded.hash && policy.value(.security, agent: "research") == "full",
          "loosened policy saved (\(saved))")
    check(policy.snapshot?.file.raw["socket"]?["path"] != nil, "socket path survives a save")

    // Another admin saves in between: stale hash → conflict path.
    let otherProfile = GatewayProfile(name: "Other policy admin", url: profile.url, authMode: .token, access: .admin)
    otherProfile.secret = profile.secret
    let other = GatewayStore(profile: otherProfile)
    other.start()
    _ = await waitFor("other admin") { other.state.isConnected && other.hello != nil }
    await other.execPolicy.load()
    other.execPolicy.set(.ask, "always", agent: nil)
    let saveResult7 = await other.execPolicy.save()
    check(saveResult7 == .saved, "other admin saves")
    other.stop()
    policy.set(.askFallback, "deny", agent: "main")
    let conflict = await policy.save()
    check(conflict == .conflict && policy.banner == .conflict && !policy.hasChanges && policy.value(.ask, agent: nil) == "always",
          "old hash → conflict, latest version shown, draft discarded")

    // `approve` then Always allow → the entry appears after the refresh.
    let chatKey = await admin.createSession(agentId: "coder", label: "Policy check")
    guard let chatKey else { return check(false, "policy chat created") }
    let chat = admin.chat(for: chatKey)
    await chat.load()
    let known = Set(admin.approvals.map(\.id))
    await chat.send("please approve this")
    _ = await waitFor("policy approval") { admin.approvals.contains { !known.contains($0.id) } }
    guard let approval = admin.approvals.first(where: { !known.contains($0.id) }) else {
        return check(false, "policy approval surfaced")
    }
    let before = policy.snapshot?.hash
    let resolved = await admin.resolveApproval(approval, decision: "allow-always")
    check(resolved == .resolved, "allow-always resolved (\(resolved))")
    let refreshed = await waitFor("policy refresh") { policy.snapshot?.hash != before }
    let entry = policy.snapshot?.file.allowlist("coder").last
    check(refreshed && entry?.isAllowAlways == true && entry?.commandText == "rm -rf ./build",
          "Always allow → entry in the coder's allowlist after refresh")
    check(policy.agentRows(agents: admin.agents).first { $0.id == "coder" }?.inFile == true, "coder now has a file entry")
    _ = await waitFor("policy approval run", timeout: 20) { !chat.isRunning }

    // Clean up: remove the entry again.
    if let index = policy.snapshot?.file.allowlist("coder").lastIndex(where: { $0.commandText == "rm -rf ./build" }) {
        policy.removeAllowlistEntry(agent: "coder", at: index)
        let saveResult8 = await policy.save()
        check(saveResult8 == .saved, "remove the new entry")
    }

    // Unknown values round-trip through the mock (D3); `*` values are inherited.
    policy.set(.security, "future-mode", agent: "ghost")
    let unknownSave = await policy.save(allowLoosening: true)
    let unknownKept = policy.snapshot?.file.raw["agents"]?["ghost"]?["security"]
    check(unknownSave == .saved && unknownKept == "future-mode", "unknown policy value saved as is (\(unknownSave))")
    policy.set(.security, nil, agent: "ghost")
    policy.set(.askFallback, "full", agent: "*")
    let wildcardAsked = await policy.save()
    check(wildcardAsked == .needsConfirmation(["All agents: If no one answers → Run anyway"]),
          "loosening * asks once, under All agents (\(wildcardAsked))")
    let wildcardSave = await policy.save(allowLoosening: true)
    check(wildcardSave == .saved && policy.effectiveValue(.askFallback, agent: "ghost") == "full"
          && policy.inheritsFromWildcard(.askFallback, agent: "ghost"), "ghost inherits the * value")
    policy.set(.askFallback, nil, agent: "*")
    let wildcardRestored = await policy.save()
    check(wildcardRestored == .saved && policy.effectiveValue(.askFallback, agent: "ghost") == "deny", "clearing * restores the default")
}
