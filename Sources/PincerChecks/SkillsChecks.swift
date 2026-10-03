import Foundation
#if DEBUG
@testable import PincerKit
#else
import PincerKit
#endif

// Skills browser + effective tools inspector (#36): pure helpers and the models against a fake
// request, then the demo and a (mock) Gateway end to end.

@MainActor
func checkSkillsTools() async {
    print("Skills & tools")
    let empty: JSONValue = ["bins": [], "anyBins": [], "env": [], "config": [], "os": []]
    func skill(_ name: String, eligible: Bool = true, disabled: Bool = false, allowlist: Bool = false,
               missing: JSONValue? = nil, source: String = "openclaw-bundled") -> SkillStatusEntry {
        SkillStatusEntry(["name": .string(name), "skillKey": .string(name), "source": .string(source), "eligible": .bool(eligible),
                          "disabled": .bool(disabled), "blockedByAllowlist": .bool(allowlist), "requirements": missing ?? empty,
                          "missing": missing ?? empty])!
    }
    let ready = skill("weather")
    let disabled = skill("slack", eligible: false, disabled: true)
    let blocked = skill("image", eligible: false, allowlist: true)
    let needsBin = skill("video", eligible: false, missing: ["bins": ["ffmpeg"]])
    let needsEnv = skill("notion", eligible: false, missing: ["env": ["NOTION_API_KEY"]])
    let otherOS = skill("apt", eligible: false, missing: ["os": ["linux"]])
    check(ready.state == .ready && ready.primaryReason == nil, "eligible → Ready")
    check(disabled.state == .disabled && disabled.primaryReason == "Disabled", "disabled → Disabled")
    check(blocked.state == .blocked && blocked.primaryReason == "Blocked by skills allowlist", "allowlist → Blocked")
    check(needsBin.state == .needsSetup && needsBin.primaryReason == "Missing binary: ffmpeg", "missing bin reason")
    check(needsEnv.primaryReason == "Needs env NOTION_API_KEY", "missing env reason")
    check(otherOS.primaryReason == "Only on Linux", "other-OS reason")
    let sections = Skills.sections([disabled, needsBin, ready, blocked])
    check(sections.map(\.state) == [.ready, .needsSetup, .blocked, .disabled], "sections in order")
    check(Skills.sections([ready, needsBin], filter: "vid").map(\.state) == [.needsSetup], "sections filter")
    check(SkillStatusEntry(["description": "nameless"]) == nil && SkillStatusEntry(["name": "x", "source": "future"])?.sourceKind == .other("future"),
          "sparse entries decode, nameless ones don't")
    check(Skills.isNewer("1.10.0", than: "1.9.0") && !Skills.isNewer("1.2.0", than: "1.2.0"), "version compare")
    check(Skills.forceRequired(GatewayError.rpc(code: "UNAVAILABLE", message: "x", details: ["results": [["ok": false, "code": "force_required"]]])),
          "force_required detected in results")

    // Tool policy text and merge.
    check(ToolsPolicy.reasonText(ToolAccessReason(kind: "profile", label: "coding profile", profile: "coding")) == "Not in profile 'coding'",
          "profile reason")
    check(ToolsPolicy.reasonText(ToolAccessReason(kind: "deny", label: "Denied by tools.deny")) == "Denied by tools.deny", "deny reason")
    let catalog = ToolCatalog(["agentId": "main", "groups": [["id": "fs", "label": "Files", "source": "core", "tools": [
        ["id": "read", "label": "read", "description": "Read", "source": "core", "defaultProfiles": ["coding"]],
        ["id": "browser", "label": "browser", "description": "Browse", "source": "core", "defaultProfiles": []],
    ]]]])
    let effective = EffectiveTools(["agentId": "main", "profile": "coding",
                                    "groups": [["id": "core", "label": "Built-in", "source": "core",
                                                "tools": [["id": "read", "label": "read", "description": "Read", "source": "core"]]]],
                                    "toolAccess": ["checked": "live-session", "profiles": [],
                                                   "tools": [["id": "browser", "status": "excluded",
                                                              "reasons": [["kind": "profile", "label": "coding profile", "profile": "coding"]]]]]])
    let inspection = ToolsInspection.build(catalog: catalog, effective: effective)
    check(inspection.summary == "Profile: coding · 1 of 2 tools allowed", "inspection summary (\(inspection.summary))")
    check(inspection.filtered(.denied).flatMap(\.tools).map(\.statusText) == ["Not in profile 'coding'"], "denied tool explains why")

    // Gating.
    let fake = FakeAgentGateway()
    let methods: Set<String> = [Skills.statusMethod, Skills.searchMethod, Skills.detailMethod, Skills.installMethod, Skills.updateMethod]
    let reader = SkillsModel(methods: { methods }, scopes: { ["operator.read"] }, request: { try await fake.request($0, $1) })
    check(reader.supportsStatus && !reader.canInstall && reader.readOnlyReason == Skills.needsAdminMessage, "read-only without admin")
    let old = SkillsModel(methods: { ["agents.list"] }, request: { try await fake.request($0, $1) })
    check(!old.supportsStatus && old.readOnlyReason == Skills.unsupportedMessage, "old gateway hides skills")
    fake.handler = { _, _ in throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin", details: ["code": "MISSING_SCOPE"]) }
    let admin = SkillsModel(methods: { methods }, request: { try await fake.request($0, $1) })
    let denied = await admin.setEnabled(disabled, true)
    check(denied == .failed(Skills.needsAdminMessage) && !admin.hasAdmin, "scope error → read-only")
    // #505: the masked editor submits pasted keys without changing punctuation or case.
    // Secrets remain write-only; the response exposes only whether the requirement is met.
    let keyGateway = FakeAgentGateway()
    keyGateway.handler = { method, _ in
        method == Skills.statusMethod ? ["skills": []] : ["ok": true]
    }
    let keyModel = SkillsModel(methods: { methods }, request: { try await keyGateway.request($0, $1) })
    let pastedKey = "sk-test_MiXeD-123+/=:@."
    _ = await keyModel.setApiKey(needsEnv, "  \(pastedKey)\n")
    check(keyGateway.calls.first { $0.method == Skills.updateMethod }?.params == ["skillKey": "notion", "apiKey": .string(pastedKey)],
          "API-key submit trims outer whitespace and preserves key bytes (#505)")
    let noTools = ToolsInspectorModel(scope: .session(key: "agent:main:main", agentId: "main"), methods: { ["agents.list"] },
                                      request: { try await fake.request($0, $1) })
    await noTools.load()
    check(noTools.error == ToolsPolicy.unsupportedMessage, "old gateway: tools unsupported")
}

@MainActor
func runDemoSkills(_ gateway: GatewayStore) async {
    print("Skills & tools (demo)")
    check(gateway.supportsSkills && gateway.supportsToolsCatalog && gateway.supportsToolsEffective, "demo advertises skills and tools")
    let skills = gateway.skills
    check(skills.canInstall && skills.canUpdate && skills.readOnlyReason == nil, "demo manages skills without admin")
    await skills.load(agentId: nil)
    check(skills.loadError == nil && skills.skills.count >= 6, "demo skills load (\(skills.skills.count))")
    check(Set(skills.skills.map(\.state)) == Set(SkillState.allCases), "demo covers every state")
    check(skills.skill(key: "video-frames")?.primaryReason == "Missing binary: ffmpeg", "demo missing binary")
    do {
        let selected = try await gateway.connection.request("skills.detail", [
            "slug": .string("@clawdia/nas-report"), "version": .string("1.3.0"),
        ])
        check(selected["latestVersion"]?["version"]?.text == "1.3.0"
              && selected["selectedRelease"]?["version"]?.text == "1.3.0",
              "demo detail selects the seeded current release")
        let older = try await gateway.connection.request("skills.detail", [
            "slug": .string("@clawdia/nas-report"), "version": .string("1.2.0"),
        ])
        check(older["latestVersion"]?["version"]?.text == "1.3.0" && older["selectedRelease"]?.isNull == true,
              "demo detail does not relabel latest metadata as an unseeded older release")
        let whitespace = try await gateway.connection.request("skills.detail", [
            "slug": .string("@clawdia/nas-report"), "version": .string("   "),
        ])
        check(whitespace["latestVersion"]?["version"]?.text == "1.3.0"
              && whitespace["selectedRelease"]?["version"]?.text == "1.3.0",
              "blank normalized detail version falls back to current")
    } catch {
        check(false, "demo detail accepts selected-release requests (\(error.localizedDescription))")
    }
    do {
        _ = try await gateway.connection.request("skills.detail", [
            "slug": .string("skills-sh:vaultsmith/obsidian-skills/obsidian-daily"),
        ])
        check(false, "demo install-only skill has no details")
    } catch let GatewayError.rpc(code, message, _) {
        check(code == "INVALID_REQUEST"
              && message == "ClawHub cannot return details for skills-sh:vaultsmith/obsidian-skills/obsidian-daily; external skill sources are install-only. Install it directly, or run \"openclaw skills install skills-sh:vaultsmith/obsidian-skills/obsidian-daily\".",
              "demo install-only detail includes upstream installation guidance")
    } catch {
        check(false, "demo install-only detail returns INVALID_REQUEST (\(error.localizedDescription))")
    }
    let invalidDetailParams: [(String, JSONValue)] = [
        ("empty version", ["slug": .string("@clawdia/nas-report"), "version": .string("")]),
        ("non-string version", ["slug": .string("@clawdia/nas-report"), "version": .number(1)]),
        ("null version", ["slug": .string("@clawdia/nas-report"), "version": .null]),
        ("empty slug", ["slug": .string("")]),
        ("non-string slug", ["slug": .number(1)]),
        ("missing slug", [:]),
        ("unknown detail key", ["slug": .string("@clawdia/nas-report"), "unexpected": true]),
    ]
    for (label, params) in invalidDetailParams {
        do {
            _ = try await gateway.connection.request("skills.detail", params)
            check(false, "demo detail rejects \(label)")
        } catch let GatewayError.rpc(code, _, _) {
            check(code == "INVALID_REQUEST", "demo detail rejects \(label) with INVALID_REQUEST")
        } catch {
            check(false, "demo detail rejects \(label) with an RPC validation error")
        }
    }
    if let notion = skills.skill(key: "notion") {
        let transientKey = "sk-demo_MiXeD-123+/=:@."
        let saved = await skills.setApiKey(notion, transientKey)
        check(saved == .done("Saved the API key for notion") && skills.skill(key: "notion")?.apiKeyIsSet == true
              && skills.skill(key: "notion")?.state == .ready, "demo pasted API key satisfies the skill requirement (#505)")
        #if DEBUG
        do {
            let report = try await gateway.connection.request(Skills.statusMethod, [:])
            let writeOnly = try await Task.detached {
                try JSONEncoder().encode(report).range(of: Data(transientKey.utf8)) == nil
            }.value
            check(writeOnly, "demo key visibility remains local to the editor: saved skill status never returns key text (#506)")
        } catch {
            check(false, "demo skill key status responds without returning secret text (#506)")
        }
        #endif
        if let keyed = skills.skill(key: "notion") {
            _ = await skills.setApiKey(keyed, "")
            check(skills.skill(key: "notion")?.apiKeyIsSet == false && skills.skill(key: "notion")?.state == .needsSetup,
                  "demo clearing the API key restores Needs Setup")
        }
    } else { check(false, "demo API-key skill exists") }
    await skills.search("nas")
    if let nas = skills.searchResults.first(where: { $0.slug == "nas-report" }),
       case .updateAvailable = skills.installState(for: nas),
       let installed = skills.skill(key: "nas-report")
    {
        let result = await skills.updateFromClawHub(installed)
        check(result == .done("Updated nas-report to 1.3.0") && skills.installState(for: nas) == .installed(version: "1.3.0"),
              "demo update (\(result))")
    } else {
        check(false, "demo nas-report has an update")
    }
    if let video = skills.skill(key: "video-frames"), let option = video.install.first {
        let installed = await skills.runInstaller(skill: video, option: option)
        check(installed == .done("Installed") && skills.skill(key: "video-frames")?.state == .ready,
              "demo installer matches the Gateway success message and fixes the missing binary")
    }

    let inspector = gateway.toolsInspector(sessionKey: "agent:main:main")
    await inspector.load()
    if let inspection = inspector.inspection {
        check(inspection.isLive && inspection.profile == "coding" && inspection.allowedCount < inspection.totalCount,
              "demo live policy (\(inspection.summary))")
        check(inspection.allTools.contains { !$0.isAllowed && !$0.reasons.isEmpty } && !inspection.notices.isEmpty,
              "demo denied tools have reasons, plus a notice")
    } else {
        check(false, "demo tools inspector (\(inspector.error ?? "nil"))")
    }

    // What ChatSessionMenu's `.sheet(item:)` relies on: every "Tools & Policy…" gives a new model
    // (so reopening re-presents), scoped to that chat, created without loading anything.
    let again = gateway.toolsInspector(sessionKey: "agent:main:main")
    check(again.id != inspector.id && again.inspection == nil && !again.isLoading, "each open gets a fresh, unloaded inspector")
    check(again.scope == .session(key: "agent:main:main", agentId: "main"), "chat inspector scope (\(again.scope))")
    // Criterion 19: works in a new chat before any run.
    if let newKey = await gateway.createSession(agentId: "research", label: "Tools check", select: false) {
        let fresh = gateway.toolsInspector(sessionKey: newKey)
        await fresh.load()
        check(fresh.scope.agentId == "research" && fresh.inspection?.isLive == true && fresh.effectiveNote == nil,
              "new chat's live policy before any run (\(fresh.error ?? fresh.effectiveNote ?? "ok"))")
        await gateway.patch(newKey, ["archived": true])
    } else {
        check(false, "demo creates a chat for the tools check")
    }
}

/// Against the mock: `admin` has Full Management; a fresh store reads without it. Restores what it changes
/// except the ClawHub install/updates (fresh mock per run).
@MainActor
func runLiveSkills(profile: GatewayProfile, admin: GatewayStore) async {
    print("Skills & tools (live)")
    let adminReady = await agentsReady(admin, "admin")
    check(adminReady, "admin connected before skills checks")
    guard admin.supportsSkills else {
        // MOCK_NO_SKILLS=1
        check(!admin.skills.supportsStatus, "gateway without skills.status → hidden")
        return
    }
    check(admin.supportsToolsCatalog && admin.supportsToolsEffective, "mock advertises tools.catalog and tools.effective")

    let readerProfile = GatewayProfile(name: "Skills reader", url: profile.url, authMode: .token)
    readerProfile.secret = profile.secret
    let readerStore = GatewayStore(profile: readerProfile)
    readerStore.start()
    await agentsReady(readerStore, "skills reader")
    defer { readerStore.stop() }
    let reader = readerStore.skills
    check(!reader.hasAdmin && !reader.canInstall && reader.readOnlyReason == Skills.needsAdminMessage, "skills reader is read-only")
    await reader.load(agentId: nil)
    check(reader.loadError == nil && reader.skills.count == 13, "reader lists skills with operator.read (\(reader.skills.count), \(reader.loadError ?? ""))")
    if let slack = reader.skill(key: "slack") {
        let refused = await reader.setEnabled(slack, true)
        check(refused == .failed(Skills.needsAdminMessage), "reader update → needs admin (\(refused))")
    }

    let skills = admin.skills
    await skills.load(agentId: nil)
    check(skills.loadError == nil && Set(skills.skills.map(\.state)) == Set(SkillState.allCases), "admin sees every state")
    check(skills.skill(key: "openai-image-gen")?.primaryReason == "Blocked by skills allowlist", "allowlist reason")
    check(skills.skill(key: "apt-updates")?.reasons.contains("Only on Linux") == true, "other-OS reason")
    check(skills.skill(key: "notion")?.primaryReason == "Needs env NOTION_API_KEY", "env reason")

    await skills.load(agentId: "research")
    check(skills.report?.agentSkillFilter == ["weather", "summarize", "github", "notion"]
          && skills.skill(key: "homelab-runbook")?.state == .blocked, "research's skill filter blocks the rest")
    await skills.load(agentId: nil)

    if let slack = skills.skill(key: "slack") {
        let enabledResult = await skills.setEnabled(slack, true)
        check(enabledResult == .done("Enabled slack") && skills.skill(key: "slack")?.state == .ready, "enable slack (\(enabledResult))")
        if let enabled = skills.skill(key: "slack") {
            _ = await skills.setEnabled(enabled, false)
            check(skills.skill(key: "slack")?.state == .disabled, "disable slack again")
        }
    }
    if let github = skills.skill(key: "github"), let option = github.install.first {
        let ran = await skills.runInstaller(skill: github, option: option)
        check(ran == .done("Installed") && skills.skill(key: "github")?.state == .ready, "gateway installer (\(ran))")
    }

    await skills.search("home")
    if let ha = skills.searchResults.first(where: { $0.slug == "home-assistant" }) {
        check(skills.installState(for: ha) == .notInstalled, "home-assistant not installed yet")
        let installed = await skills.installFromClawHub(ha)
        check(installed == .done("Installed Home Assistant 2.4.1") && skills.installState(for: ha) == .installed(version: "2.4.1"),
              "ClawHub install (\(installed))")
    } else {
        check(false, "search finds home-assistant (\(skills.searchError ?? ""))")
    }
    await skills.search("obsidian")
    if let external = skills.searchResults.first(where: \.installOnly) {
        do {
            _ = try await skills.detail(external.installRef)
            check(false, "install-only results have no details")
        } catch {
            check(AgentManagementError.classify(error).message.contains("install-only"), "install-only detail refused")
        }
    }
    if let nas = skills.skill(key: "nas-report") {
        let updated = await skills.updateFromClawHub(nas)
        check(updated == .done("Updated nas-report to 1.3.0"), "ClawHub update (\(updated))")
    }
    if let grocery = skills.skill(key: "grocery-list") {
        let first = await skills.updateFromClawHub(grocery)
        if case .forceRequired = first {
            check(true, "locally modified → force required")
        } else {
            check(false, "locally modified → force required (\(first))")
        }
        let forced = await skills.updateFromClawHub(grocery, force: true)
        check(forced == .done("Updated grocery-list to 1.0.0"), "forced update (\(forced))")
    }

    let chat = admin.toolsInspector(sessionKey: "agent:main:main")
    await chat.load()
    if let inspection = chat.inspection {
        let tools = Dictionary(inspection.allTools.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        check(inspection.isLive && inspection.profile == "coding", "live policy for main (\(inspection.summary))")
        check(tools["x_search"]?.reasons == ["Denied by tools.deny"], "deny reason (\(tools["x_search"]?.reasons ?? []))")
        check(tools["read"]?.isAllowed == true && tools.values.contains { $0.source == .mcp }, "allowed and MCP tools")
        check(!inspection.notices.isEmpty, "notices shown")
    } else {
        check(false, "tools inspector for main (\(chat.error ?? ""))")
    }
    let discord = admin.toolsInspector(sessionKey: "agent:main:discord:channel:123")
    await discord.load()
    let exec = discord.inspection?.allTools.first { $0.id == "exec" }
    check(exec?.isAllowed == false && exec?.reasons == ["Denied for this session"], "session-denied exec (\(exec?.reasons ?? []))")
    check(discord.inspection?.allTools.contains { $0.source == .channel } == true, "channel tools listed")
    let stale = admin.toolsInspector(sessionKey: "agent:main:nope")
    await stale.load()
    check(stale.inspection?.isLive == false && stale.effectiveNote != nil, "unknown session falls back to the catalog")
}
