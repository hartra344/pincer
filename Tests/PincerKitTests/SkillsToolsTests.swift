import Foundation
import Testing
@testable import PincerKit

/// Skills browser + effective tools inspector (#36): upstream wire shapes, state/reason text,
/// tool policy explanations, capability and scope gating, and the demo Gateway end to end.
@Suite("Skills and tools")
struct SkillsToolsTests {
    // MARK: Fixtures (upstream shapes: SkillStatusEntry, tools.catalog, tools.effective)

    static func skill(_ name: String, source: String = "openclaw-bundled", eligible: Bool = true, disabled: Bool = false,
                      blockedByAllowlist: Bool = false, blockedByAgentFilter: Bool = false,
                      platformIncompatible: Bool = false, requirements: JSONValue? = nil, missing: JSONValue? = nil,
                      extra: [String: JSONValue] = [:]) -> JSONValue {
        let empty: JSONValue = ["bins": [], "anyBins": [], "env": [], "config": [], "os": []]
        var object: [String: JSONValue] = [
            "name": .string(name), "description": .string("The \(name) skill."), "source": .string(source),
            "bundled": .bool(source == "openclaw-bundled"), "filePath": .string("/skills/\(name)/SKILL.md"),
            "baseDir": .string("/skills/\(name)"), "skillKey": .string(name), "always": false, "disabled": .bool(disabled),
            "blockedByAllowlist": .bool(blockedByAllowlist), "blockedByAgentFilter": .bool(blockedByAgentFilter),
            "eligible": .bool(eligible), "platformIncompatible": .bool(platformIncompatible), "modelVisible": .bool(eligible),
            "userInvocable": true, "commandVisible": .bool(eligible), "requirements": requirements ?? empty,
            "missing": missing ?? empty, "configChecks": [], "install": [],
        ]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    static func entry(_ json: JSONValue) -> SkillStatusEntry { SkillStatusEntry(json)! }

    // MARK: Decoding

    @Test func decodesUpstreamStatusEntry() throws {
        let json = Fixtures.json("""
        {"workspaceDir":"/Users/claw/.openclaw/workspace","managedSkillsDir":"/Users/claw/.openclaw/skills","agentId":"main",
         "agentSkillFilter":["github"],
         "skills":[{"name":"github","description":"Use gh.","source":"openclaw-bundled","bundled":true,
           "filePath":"/opt/skills/github/SKILL.md","baseDir":"/opt/skills/github","skillKey":"github","emoji":"🐙",
           "homepage":"https://cli.github.com","primaryEnv":"GH_TOKEN","always":false,"disabled":false,"blockedByAllowlist":false,
           "blockedByAgentFilter":false,"eligible":false,"platformIncompatible":false,"modelVisible":false,"userInvocable":true,
           "commandVisible":false,
           "requirements":{"bins":["gh"],"anyBins":["rg","grep"],"env":["GH_TOKEN"],"config":["channels.github"],"os":["darwin"]},
           "missing":{"bins":["gh"],"anyBins":[],"env":["GH_TOKEN"],"config":["channels.github"],"os":[]},
           "configChecks":[{"path":"channels.github","satisfied":false}],
           "install":[{"id":"brew","kind":"brew","label":"Install GitHub CLI (brew)","bins":["gh"]}],
           "clawhub":{"status":"linked","valid":true,"registry":"https://clawhub.ai","slug":"github","ownerHandle":"openclaw",
             "installedVersion":"1.0.0","installedAt":1790000000000,"originPath":"/o","lockPath":"/l"},
           "skillCard":{"present":true,"path":"/opt/skills/github/SKILL_CARD.md","sizeBytes":120}}]}
        """)
        let report = SkillStatusReport(json)
        #expect(report.agentId == "main" && report.workspaceDir == "/Users/claw/.openclaw/workspace")
        #expect(report.managedSkillsDir == "/Users/claw/.openclaw/skills" && report.agentSkillFilter == ["github"])
        let skill = try #require(report.skills.first)
        #expect(skill.id == "github" && skill.name == "github" && skill.emoji == "🐙" && skill.homepage == "https://cli.github.com")
        #expect(skill.bundled && !skill.eligible && skill.userInvocable && !skill.modelVisible)
        #expect(skill.requirements == SkillRequirements(bins: ["gh"], anyBins: ["rg", "grep"], env: ["GH_TOKEN"],
                                                        config: ["channels.github"], os: ["darwin"]))
        #expect(skill.missing.bins == ["gh"] && skill.missing.env == ["GH_TOKEN"] && skill.missing.anyBins.isEmpty)
        #expect(skill.configChecks == [SkillConfigCheck(path: "channels.github", satisfied: false)])
        #expect(skill.install == [SkillInstallOption(id: "brew", kind: "brew", label: "Install GitHub CLI (brew)", bins: ["gh"])])
        #expect(skill.clawhub?.valid == true && skill.clawhub?.slug == "github" && skill.clawhub?.installedVersion == "1.0.0")
        #expect(skill.clawhub?.ownerHandle == "openclaw" && skill.clawhub?.installedAt == 1_790_000_000_000)
        #expect(skill.isClawHubTracked && skill.sourceKind == .clawhub)
        #expect(skill.apiKeyEnv == "GH_TOKEN" && !skill.apiKeyIsSet)
    }

    @Test func toleratesSparseAndUnknownFields() {
        let sparse = SkillStatusEntry(["name": "mystery", "source": "agents-skills-personal", "futureField": ["x": 1]])
        #expect(sparse?.skillKey == "mystery" && sparse?.description == "" && sparse?.requirements.isEmpty == true)
        #expect(sparse?.sourceKind == .other("agents-skills-personal") && sparse?.state == .needsSetup)
        #expect(SkillStatusEntry(["skillKey": "only-key"])?.name == "only-key")
        #expect(SkillStatusEntry(["description": "no name"]) == nil)
        #expect(SkillStatusEntry("not an object") == nil)
        #expect(SkillStatusReport(["skills": [["name": "ok"], "junk", ["nope": true]]]).skills.map(\.name) == ["ok"])
        #expect(SkillStatusReport([:]).skills.isEmpty)
        let invalidLink = Self.entry(Self.skill("x", source: "openclaw-workspace", eligible: false,
                                                extra: ["clawhub": ["status": "invalid", "valid": false, "reason": "lock missing"]]))
        #expect(!invalidLink.isClawHubTracked && invalidLink.reasons.contains("ClawHub link invalid: lock missing"))
    }

    @Test func sourceKinds() {
        #expect(Self.entry(Self.skill("a")).sourceKind == .bundled)
        #expect(Self.entry(Self.skill("b", source: "openclaw-workspace")).sourceKind == .workspace)
        #expect(Self.entry(Self.skill("c", source: "openclaw-managed")).sourceKind == .managed)
        #expect(Self.entry(Self.skill("d", source: "openclaw-extra")).sourceKind == .extra)
        #expect(SkillSourceKind.bundled.label == "Bundled" && SkillSourceKind.clawhub.label == "ClawHub")
        #expect(SkillSourceKind.other("openclaw-workshop").label == "Workshop")
    }

    // MARK: State and reasons

    @Test func stateClassificationAndReasons() {
        let ready = Self.entry(Self.skill("weather"))
        #expect(ready.state == .ready && ready.reasons.isEmpty && ready.primaryReason == nil)

        let disabled = Self.entry(Self.skill("slack", eligible: false, disabled: true))
        #expect(disabled.state == .disabled && disabled.primaryReason == "Disabled")

        let allowlisted = Self.entry(Self.skill("openai-image-gen", eligible: false, blockedByAllowlist: true))
        #expect(allowlisted.state == .blocked && allowlisted.primaryReason == "Blocked by skills allowlist")

        // The agent filter doesn't change `eligible` upstream, but the skill isn't available to that agent.
        let filtered = Self.entry(Self.skill("homelab", eligible: true, blockedByAgentFilter: true))
        #expect(filtered.state == .blocked && filtered.primaryReason == "Blocked by agent skill filter")

        let disabledAndBlocked = Self.entry(Self.skill("both", eligible: false, disabled: true, blockedByAllowlist: true))
        #expect(disabledAndBlocked.state == .disabled && disabledAndBlocked.reasons == ["Disabled", "Blocked by skills allowlist"])

        let missing = Self.entry(Self.skill("github", eligible: false,
                                            requirements: ["bins": ["gh", "jq"], "anyBins": ["rg", "grep"], "env": ["GITHUB_TOKEN"],
                                                           "config": ["channels.github"], "os": []],
                                            missing: ["bins": ["gh"], "anyBins": ["rg", "grep"], "env": ["GITHUB_TOKEN"],
                                                      "config": ["channels.github"], "os": []]))
        #expect(missing.state == .needsSetup)
        #expect(missing.reasons == ["Missing binary: gh", "Needs one of: rg, grep", "Needs env GITHUB_TOKEN", "Needs config channels.github"])
        #expect(missing.primaryReason == "Missing binary: gh")

        let linuxOnly = Self.entry(Self.skill("apt-updates", eligible: false, platformIncompatible: true,
                                              requirements: ["os": ["linux"]], missing: ["os": ["linux"]]))
        #expect(linuxOnly.state == .needsSetup && linuxOnly.primaryReason == "Only on Linux")
        #expect(Self.entry(Self.skill("remote", eligible: false, platformIncompatible: true)).primaryReason == "Not available on this platform")
        #expect(Self.entry(Self.skill("opaque", eligible: false)).primaryReason == "Requirements not met")
        #expect(Skills.osName("darwin") == "macOS" && Skills.osName("win32") == "Windows" && Skills.osName("aix") == "aix")
    }

    @Test func requirementChecklist() {
        let skill = Self.entry(Self.skill("x", eligible: false,
                                          requirements: ["bins": ["curl", "ffmpeg"], "anyBins": ["uv", "python3"], "env": ["API_KEY"],
                                                         "config": ["a.b", "c.d"], "os": ["darwin"]],
                                          missing: ["bins": ["ffmpeg"], "env": ["API_KEY"], "config": ["c.d"]],
                                          extra: ["configChecks": [["path": "a.b", "satisfied": true], ["path": "c.d", "satisfied": false]]]))
        let checks = skill.requirementChecks.map { "\($0.kind.rawValue) \($0.name) \($0.satisfied ? "✓" : "✗")" }
        #expect(checks == ["bin curl ✓", "bin ffmpeg ✗", "anyBins uv, python3 ✓", "env API_KEY ✗", "config a.b ✓", "config c.d ✗", "os macOS ✓"])
        #expect(Set(skill.requirementChecks.map(\.id)).count == skill.requirementChecks.count, "ids are unique")
        let keyed = Self.entry(Self.skill("n", extra: ["primaryEnv": "NOTION_API_KEY"]))
        #expect(keyed.apiKeyIsSet, "a satisfied primaryEnv reads as set, never as a value")
    }

    @Test func sectionsOrderFilterAndOmitEmpty() {
        let skills = [
            Self.skill("zeta"), Self.skill("alpha"), Self.skill("slack", eligible: false, disabled: true),
            Self.skill("gh", eligible: false, missing: ["bins": ["gh"]]), Self.skill("img", eligible: false, blockedByAllowlist: true),
        ].map(Self.entry)
        let sections = Skills.sections(skills)
        #expect(sections.map(\.state) == [.ready, .needsSetup, .blocked, .disabled])
        #expect(sections.map(\.state.title) == ["Ready", "Needs Setup", "Blocked", "Disabled"])
        #expect(sections[0].skills.map(\.name) == ["alpha", "zeta"], "sorted by name")
        #expect(Skills.sections(skills, filter: "  ZET ").map(\.state) == [.ready])
        #expect(Skills.sections(skills, filter: "the gh skill").first?.skills.map(\.name) == ["gh"], "matches descriptions")
        #expect(Skills.sections(skills, filter: "nothing-matches").isEmpty)
        #expect(Skills.sections([]).isEmpty)
    }

    // MARK: ClawHub

    @Test func decodesSearchAndDetail() throws {
        let results = Fixtures.json("""
        {"results":[
          {"score":0.8,"slug":"nas-report","registry":"https://clawhub.ai","ownerHandle":"clawdia","installRef":"@clawdia/nas-report",
           "displayName":"NAS Report","summary":"NAS health.","icon":null,"version":"1.3.0","updatedAt":1790000000000},
          {"score":0,"slug":"obsidian-daily","registry":"https://clawhub.ai","ownerHandle":null,
           "installRef":"skills-sh:vaultsmith/obsidian-skills/obsidian-daily","installOnly":true,"trustState":"not-scanned-by-clawhub",
           "displayName":"Obsidian Daily Notes"},
          {"displayName":"no slug"}]}
        """)["results"]?.array?.compactMap(ClawHubSearchResult.init) ?? []
        #expect(results.count == 2)
        #expect(results[0].id == "@clawdia/nas-report" && results[0].version == "1.3.0" && !results[0].installOnly && !results[0].isUnscanned)
        #expect(results[1].ownerHandle == nil && results[1].installOnly && results[1].isUnscanned && results[1].summary == nil)
        #expect(ClawHubSearchResult(["slug": "bare"])?.installRef == "bare")

        let detail = ClawHubSkillDetail(Fixtures.json("""
        {"skill":{"slug":"home-assistant","displayName":"Home Assistant","summary":"Lights.","icon":null,"tags":{"latest":"2.4.1"},
          "channel":null,"isOfficial":true,"createdAt":1,"updatedAt":2},
         "latestVersion":{"version":"2.4.1","createdAt":2,"changelog":"Areas."},
         "metadata":{"os":["darwin","linux"],"systems":null},
         "owner":{"handle":"openclaw","displayName":"OpenClaw","image":null,"official":true}}
        """))
        #expect(detail.slug == "home-assistant" && detail.isOfficial && detail.latestVersion == "2.4.1" && detail.changelog == "Areas.")
        #expect(detail.os == ["darwin", "linux"] && detail.ownerHandle == "openclaw" && detail.tags == ["latest": "2.4.1"])
        let nulls = ClawHubSkillDetail(["skill": .null, "latestVersion": .null, "metadata": .null, "owner": .null])
        #expect(nulls.slug == nil && nulls.latestVersion == nil && nulls.os.isEmpty && !nulls.isOfficial)
    }

    @Test func installStateAndVersions() throws {
        let tracked = Self.entry(Self.skill("nas-report", source: "openclaw-workspace",
                                            extra: ["clawhub": ["status": "linked", "valid": true, "slug": "nas-report",
                                                                "ownerHandle": "clawdia", "installedVersion": "1.2.0"]]))
        func result(_ slug: String, owner: String?, version: String?) -> ClawHubSearchResult {
            var json: [String: JSONValue] = ["slug": .string(slug), "installRef": .string("@\(owner ?? "x")/\(slug)"), "displayName": "X"]
            if let owner { json["ownerHandle"] = .string(owner) }
            if let version { json["version"] = .string(version) }
            return ClawHubSearchResult(.object(json))!
        }
        #expect(Skills.installState(for: result("nas-report", owner: "clawdia", version: "1.3.0"), in: [tracked])
            == .updateAvailable(installed: "1.2.0", latest: "1.3.0"))
        #expect(Skills.installState(for: result("nas-report", owner: "CLAWDIA", version: "1.2.0"), in: [tracked]) == .installed(version: "1.2.0"))
        #expect(Skills.installState(for: result("nas-report", owner: "someone-else", version: "9.0.0"), in: [tracked]) == .notInstalled,
                "another publisher's same slug isn't this install")
        #expect(Skills.installState(for: result("pi-fleet", owner: "pilab", version: "1.0.0"), in: [tracked]) == .notInstalled)
        // A local skill that merely shares the name isn't ClawHub-installed.
        #expect(Skills.installState(for: result("weather", owner: "x", version: "1.0.0"), in: [Self.entry(Self.skill("weather"))]) == .notInstalled)
        #expect(ClawHubInstallState.updateAvailable(installed: "1", latest: "2").label == "Update available")
        #expect(ClawHubInstallState.installed(version: nil).label == "Installed" && ClawHubInstallState.notInstalled.label == nil)

        #expect(Skills.isNewer("1.10.0", than: "1.9.2") && Skills.isNewer("2.0", than: "1.99.99") && Skills.isNewer("v1.2.1", than: "1.2"))
        #expect(!Skills.isNewer("1.2.0", than: "1.2") && !Skills.isNewer("1.2.0", than: "1.3.0") && !Skills.isNewer("1.2.0-beta", than: "1.2.0"))
    }

    @Test func forceRequiredDetection() {
        let results: JSONValue = ["results": [["ok": false, "code": "force_required",
                                               "error": "Skill \"x\" has local changes. Updating replaces the installed skill directory."]]]
        #expect(Skills.forceRequired(GatewayError.rpc(code: "UNAVAILABLE", message: "…", details: results)))
        #expect(Skills.forceRequired(GatewayError.rpc(code: "UNAVAILABLE", message: "…", details: ["code": "force_required"])))
        #expect(!Skills.forceRequired(GatewayError.rpc(code: "UNAVAILABLE", message: "ClawHub request failed", details: ["results": [["ok": false, "error": "x"]]])))
        #expect(!Skills.forceRequired(GatewayError.rpc(code: "INVALID_REQUEST", message: "nope", details: nil)))
        #expect(!Skills.forceRequired(CancellationError()))
    }

    @Test func settingsSearchFindsSkills() {
        #expect(SettingsCatalog.destinations(matching: "skills").map(\.destination) == [.skills])
        #expect(SettingsCatalog.destinations(matching: "clawhub").map(\.title) == ["Skills"])
        #expect(SettingsCatalog.destinations(matching: "tools").contains { $0.destination == .skills })
    }

    @Test func confirmationCopy() {
        #expect(Skills.installWarning == "This downloads the skill into the default agent's workspace on the Gateway host. Skills can run commands and read files with the agent's permissions. Only install skills you trust.")
        #expect(Skills.clawHubInstallTitle("NAS Report") == "Install “NAS Report” from ClawHub?")
        #expect(Skills.installerTitle(SkillInstallOption(id: "brew", kind: "brew", label: "Install ffmpeg (brew)"))
            == "Run installer “Install ffmpeg (brew)” on the Gateway host?")
        #expect(Skills.updateTitle("NAS Report") == "Update “NAS Report”?")
        #expect(Skills.forceReplaceMessage("Grocery List") == "Grocery List was changed locally since it was installed. Replace it anyway?")
        #expect(Skills.installMessage().hasPrefix("This downloads the skill into the default agent's workspace on the Gateway host."))
        #expect(Skills.installMessage(agentName: "Scout").contains("Scout's workspace"))
        #expect(Skills.needsAdminMessage == "You can view skills. Turn on Full Management under Connection, then approve this device on the Gateway host.")
    }

    // MARK: Tools policy

    static let catalogJSON = Fixtures.json("""
    {"agentId":"main","profiles":[{"id":"minimal","label":"Minimal"},{"id":"coding","label":"Coding"},
       {"id":"messaging","label":"Messaging"},{"id":"full","label":"Full"}],
     "groups":[
      {"id":"fs","label":"Files","source":"core","tools":[
        {"id":"read","label":"read","description":"Read file contents","source":"core","defaultProfiles":["coding"]},
        {"id":"write","label":"write","description":"Create or overwrite files","source":"core","defaultProfiles":["coding"]}]},
      {"id":"web","label":"Web","source":"core","tools":[
        {"id":"x_search","label":"x_search","description":"Search X posts","source":"core","defaultProfiles":["coding"]}]},
      {"id":"ui","label":"UI","source":"core","tools":[
        {"id":"browser","label":"browser","description":"Control web browser","source":"core","defaultProfiles":[]}]},
      {"id":"runtime","label":"Runtime","source":"core","tools":[
        {"id":"exec","label":"exec","description":"Run shell commands","source":"core","defaultProfiles":["coding"]}]},
      {"id":"plugin:voice-call","label":"Voice Call","source":"plugin","pluginId":"voice-call","tools":[
        {"id":"voice_call","label":"voice_call","description":"Place calls","source":"plugin","pluginId":"voice-call",
         "optional":true,"risk":"high","defaultProfiles":[]}]}]}
    """)

    static let effectiveJSON = Fixtures.json("""
    {"agentId":"main","profile":"coding",
     "groups":[
      {"id":"core","label":"Built-in tools","source":"core","tools":[
        {"id":"read","label":"read","description":"Read file contents","rawDescription":"Read file contents","source":"core"},
        {"id":"write","label":"write","description":"Create or overwrite files","rawDescription":"x","source":"core"},
        {"id":"exec","label":"exec","description":"Run shell commands","rawDescription":"x","source":"core","deniedBySession":true}]},
      {"id":"channel","label":"Channel tools","source":"channel","tools":[
        {"id":"discord_react","label":"discord_react","description":"React","rawDescription":"React","source":"channel","channelId":"discord"}]},
      {"id":"mcp","label":"MCP tools","source":"mcp","tools":[
        {"id":"home-assistant__get_state","label":"get_state","description":"Read state","rawDescription":"Read state","source":"mcp",
         "mcpServer":"home-assistant","mcpToolName":"get_state","risk":"low"}]},
      {"id":"future","label":"Future","source":"quantum","tools":[
        {"id":"qubit","label":"qubit","description":"?","rawDescription":"?","source":"quantum"}]}],
     "notices":[{"id":"mcp-not-yet-connected","severity":"warning","message":"raw text","servers":["paperless"]},
                {"id":"browser-filtered-by-profile","severity":"info","message":"Browser is configured, but…"}],
     "toolAccess":{"checked":"live-session","profiles":[{"profile":"coding","source":"tools.profile","active":true}],
      "tools":[
        {"id":"read","status":"available","reasons":[]},
        {"id":"x_search","status":"excluded","reasons":[{"kind":"deny","label":"Denied by tools.deny","source":"tools.deny"}]},
        {"id":"browser","status":"excluded","reasons":[{"kind":"profile","label":"coding profile","source":"tools.profile","profile":"coding"}],
         "alsoAllowPath":"tools.alsoAllow"},
        {"id":"exec","status":"excluded","reasons":[{"kind":"session","label":"Denied by session tool overrides"}]},
        {"id":"gateway","status":"excluded","reasons":[{"kind":"allowlist","label":"Not included in agents.entries.main.tools.allow"}]},
        {"id":"mystery","status":"weird","reasons":[]}]}}
    """)

    @Test func decodesCatalogAndEffective() throws {
        let catalog = ToolCatalog(Self.catalogJSON)
        #expect(catalog.agentId == "main" && catalog.profiles.map(\.id) == ["minimal", "coding", "messaging", "full"])
        #expect(catalog.groups.map(\.id) == ["fs", "web", "ui", "runtime", "plugin:voice-call"])
        let voice = try #require(catalog.groups.last?.tools.first)
        #expect(voice.source == .plugin && voice.pluginId == "voice-call" && voice.optional && voice.risk == "high")
        #expect(catalog.groups[0].tools[0].isIn(profile: "coding") && !catalog.groups[0].tools[0].isIn(profile: "messaging"))
        #expect(catalog.groups[0].tools[0].isIn(profile: "full"), "full includes everything")

        let effective = EffectiveTools(Self.effectiveJSON)
        #expect(effective.agentId == "main" && effective.profile == "coding")
        #expect(effective.groups.map(\.source) == [.core, .channel, .mcp, .other("quantum")])
        #expect(effective.groups[0].tools.last?.deniedBySession == true)
        #expect(effective.groups[1].tools[0].channelId == "discord" && effective.groups[2].tools[0].mcpServer == "home-assistant")
        #expect(effective.notices.map(\.id) == ["mcp-not-yet-connected", "browser-filtered-by-profile"])
        #expect(effective.notices[0].isWarning && effective.notices[0].servers == ["paperless"] && !effective.notices[1].isWarning)
        let access = try #require(effective.access)
        #expect(access.checked == "live-session" && access.profiles.first?.active == true)
        #expect(access.tools.first { $0.id == "browser" }?.alsoAllowPath == "tools.alsoAllow")
        #expect(access.tools.first { $0.id == "mystery" }?.status == .other("weird"))
        #expect(ToolAccessStatus("allowed").isAllowed && ToolAccessStatus("available").isAllowed)
        #expect(!ToolAccessStatus("excluded").isAllowed && !ToolAccessStatus("unavailable").isAllowed && !ToolAccessStatus("weird").isAllowed)

        let bare = EffectiveTools(["groups": [["id": "core", "tools": [["id": "read"]]]]])
        #expect(bare.profile == nil && bare.access == nil && bare.notices.isEmpty)
        #expect(ToolSourceKind(nil) == .core && ToolSourceKind("mcp").label == "MCP" && ToolSourceKind("x").label == "x")
    }

    @Test func policyExplanations() {
        #expect(ToolsPolicy.reasonText(ToolAccessReason(kind: "profile", label: "messaging profile", profile: "messaging")) == "Not in profile 'messaging'")
        #expect(ToolsPolicy.reasonText(ToolAccessReason(kind: "deny", label: "Denied by tools.deny", source: "tools.deny")) == "Denied by tools.deny")
        #expect(ToolsPolicy.reasonText(ToolAccessReason(kind: "allowlist", label: "Not included in tools.allow")) == "Not included in tools.allow")
        #expect(ToolsPolicy.reasonText(ToolAccessReason(kind: "session", label: "")) == "Denied for this session")
        #expect(ToolsPolicy.reasonText(ToolAccessReason(kind: "runtime", label: "Not included in the session preview")) == "Not included in the session preview")
        #expect(ToolsPolicy.reasonText(ToolAccessReason(kind: "sandbox", label: "")) == "Denied by policy")
        let notice = EffectiveTools(Self.effectiveJSON).notices
        #expect(ToolsPolicy.noticeText(notice[0]) == "MCP servers haven't connected yet, so their tools may be missing.")
        #expect(ToolsPolicy.noticeText(notice[1]) == "Browser is configured, but…", "unknown notices show upstream's text")
    }

    @Test func inspectionMergesCatalogAndEffective() throws {
        let inspection = ToolsInspection.build(catalog: ToolCatalog(Self.catalogJSON), effective: EffectiveTools(Self.effectiveJSON))
        #expect(inspection.isLive && inspection.profile == "coding")
        let tools = Dictionary(uniqueKeysWithValues: inspection.allTools.map { ($0.id, $0) })
        #expect(tools.count == inspection.totalCount, "each tool appears once")
        #expect(tools["read"]?.isAllowed == true && tools["read"]?.statusText == "Allowed")
        #expect(tools["x_search"]?.isAllowed == false && tools["x_search"]?.reasons == ["Denied by tools.deny"])
        #expect(tools["browser"]?.statusText == "Not in profile 'coding'")
        #expect(tools["exec"]?.isAllowed == false && tools["exec"]?.reasons == ["Denied for this session"])
        #expect(tools["voice_call"]?.isAllowed == false && tools["voice_call"]?.sourceLabel == "Plugin voice-call")
        #expect(tools["discord_react"]?.isAllowed == true && tools["discord_react"]?.sourceLabel == "Channel discord")
        #expect(tools["home-assistant__get_state"]?.label == "get_state" && tools["home-assistant__get_state"]?.sourceLabel == "MCP home-assistant")
        #expect(tools["gateway"]?.isAllowed == false && tools["gateway"]?.reasons == ["Not included in agents.entries.main.tools.allow"],
                "tools only toolAccess knows still show with their reason")
        #expect(tools["qubit"]?.isAllowed == true && tools["qubit"]?.source == .other("quantum"))
        #expect(inspection.groups.first?.id == "fs", "catalog groups keep upstream order")
        #expect(inspection.allowedCount == 5)
        #expect(inspection.summary == "Profile: coding · 5 of \(inspection.totalCount) tools allowed")
        #expect(inspection.notices.count == 2)

        let denied = inspection.filtered(.denied).flatMap(\.tools).map(\.id)
        #expect(Set(denied) == ["x_search", "browser", "exec", "voice_call", "gateway", "mystery"])
        let allowedTools = inspection.filtered(.allowed).flatMap(\.tools)
        #expect(allowedTools.allSatisfy { $0.isAllowed })
        #expect(inspection.filtered(.all, search: "STATE").flatMap(\.tools).map(\.id) == ["home-assistant__get_state"])
        #expect(inspection.filtered(.allowed, search: "browser").isEmpty, "empty groups are dropped")
        #expect(ToolFilter.allCases.map(\.title) == ["All", "Allowed", "Denied"])
    }

    @Test func catalogOnlyInspectionUsesProfileMembership() {
        let catalog = ToolCatalog(Self.catalogJSON)
        let coding = ToolsInspection.build(catalog: catalog, effective: nil, profile: "coding")
        #expect(!coding.isLive && coding.profile == "coding" && coding.notices.isEmpty)
        let tools = Dictionary(uniqueKeysWithValues: coding.allTools.map { ($0.id, $0) })
        #expect(tools["read"]?.isAllowed == true && tools["exec"]?.isAllowed == true)
        #expect(tools["browser"]?.isAllowed == false && tools["browser"]?.reasons == ["Not in profile 'coding'"])
        #expect(tools["voice_call"]?.reasons == ["Optional plugin tool not enabled"])
        let unknown = ToolsInspection.build(catalog: catalog, effective: nil)
        #expect(unknown.profile == nil && unknown.summary == "\(unknown.allowedCount) of \(unknown.totalCount) tools allowed")
        #expect(ToolsInspection.build(catalog: nil, effective: nil).groups.isEmpty)
    }

    // MARK: Capability and scope gating

    @MainActor
    final class Recorder {
        var calls: [(method: String, params: JSONValue)] = []
        var handler: (String, JSONValue) throws -> JSONValue = { _, _ in [:] }
        func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
            self.calls.append((method, params))
            return try self.handler(method, params)
        }
    }

    @MainActor @Test func capabilityGating() {
        let recorder = Recorder()
        let all = Set(DemoGateway.skillMethods)
        let admin = SkillsModel(methods: { all }, request: { try recorder.request($0, $1) })
        #expect(admin.supportsStatus && admin.supportsSearch && admin.supportsDetail && admin.canInstall && admin.canUpdate)
        #expect(admin.readOnlyReason == nil)

        let reader = SkillsModel(methods: { all }, scopes: { ["operator.read", "operator.write"] }, request: { try recorder.request($0, $1) })
        #expect(reader.supportsStatus && reader.supportsSearch, "browsing works read-only")
        #expect(!reader.hasAdmin && !reader.canInstall && !reader.canUpdate && reader.readOnlyReason == Skills.needsAdminMessage)

        let statusOnly = SkillsModel(methods: { ["skills.status"] }, request: { try recorder.request($0, $1) })
        #expect(statusOnly.supportsStatus && !statusOnly.supportsSearch && !statusOnly.supportsDetail)
        #expect(!statusOnly.canInstall && !statusOnly.canUpdate && statusOnly.readOnlyReason == Skills.unsupportedMessage)

        let none = SkillsModel(methods: { ["agents.list"] }, request: { try recorder.request($0, $1) })
        #expect(!none.supportsStatus)
        let unknown = SkillsModel(methods: { nil }, request: { try recorder.request($0, $1) })
        #expect(unknown.supportsStatus, "an unknown method list doesn't hide the page")

        let demo = SkillsModel(scopes: { [] }, allowsWritesWithoutAdmin: true, request: { try recorder.request($0, $1) })
        #expect(demo.canInstall && demo.canUpdate && demo.readOnlyReason == nil)
        #expect(recorder.calls.isEmpty, "capability checks never hit the Gateway")
    }

    @MainActor @Test func scopeAndUnknownMethodErrors() async {
        let recorder = Recorder()
        let model = SkillsModel(methods: { Set(DemoGateway.skillMethods) }, request: { try recorder.request($0, $1) })
        let skill = Self.entry(Self.skill("slack", eligible: false, disabled: true))
        recorder.handler = { method, _ in
            if method == "skills.update" {
                throw GatewayError.rpc(code: "FORBIDDEN", message: "missing scope: operator.admin",
                                       details: ["code": "MISSING_SCOPE", "scope": "operator.admin"])
            }
            return ["skills": []]
        }
        let result = await model.setEnabled(skill, true)
        #expect(result == .failed(Skills.needsAdminMessage))
        #expect(recorder.calls.last?.params == ["skillKey": "slack", "enabled": true])
        #expect(!model.hasAdmin && !model.canUpdate && model.readOnlyReason == Skills.needsAdminMessage)
        #expect(model.actionError == Skills.needsAdminMessage)

        recorder.handler = { method, _ in throw GatewayError.rpc(code: "UNKNOWN_METHOD", message: "unknown method: \(method)", details: nil) }
        await model.search("nas")
        #expect(!model.supportsSearch && model.searchError == Skills.unsupportedMessage && model.searchedQuery == "nas")
        await model.load(agentId: nil)
        #expect(!model.supportsStatus && model.loadError == Skills.unsupportedMessage && model.report == nil)
    }

    @MainActor @Test func requestShapes() async throws {
        let recorder = Recorder()
        recorder.handler = { method, _ in method == "skills.status" ? ["agentId": "research", "skills": []] : ["ok": true] }
        let model = SkillsModel(request: { try recorder.request($0, $1) })
        await model.load(agentId: "research")
        #expect(recorder.calls.last?.method == "skills.status" && recorder.calls.last?.params == ["agentId": "research"])
        await model.load(agentId: nil)
        #expect(recorder.calls.last?.params == [:])
        await model.load(agentId: "research")
        recorder.calls = []

        let result = try #require(ClawHubSearchResult(["slug": "nas-report", "installRef": "@clawdia/nas-report", "displayName": "NAS Report"]))
        _ = await model.installFromClawHub(result)
        #expect(recorder.calls[0].params == ["source": "clawhub", "slug": "@clawdia/nas-report", "agentId": "research"],
                "installs send installRef, not the bare slug")
        #expect(recorder.calls[1].method == "skills.status", "mutations reload the list")
        recorder.calls = []
        let github = Self.entry(Self.skill("github", eligible: false))
        _ = await model.runInstaller(skill: github, option: SkillInstallOption(id: "brew", kind: "brew", label: "Install"))
        #expect(recorder.calls[0].params == ["name": "github", "installId": "brew", "agentId": "research"])
        _ = await model.setApiKey(github, "  secret  ")
        #expect(recorder.calls.last { $0.method == "skills.update" }?.params == ["skillKey": "github", "apiKey": "secret"])
        _ = await model.setEnv(github, name: " HASS_URL ", value: "http://ha")
        #expect(recorder.calls.last { $0.method == "skills.update" }?.params == ["skillKey": "github", "env": ["HASS_URL": "http://ha"]],
                "config updates carry no agentId (skills.entries is gateway-wide)")
        recorder.calls = []
        #expect(await model.setEnv(github, name: "  ", value: "x") == .failed("Enter a variable name."))
        #expect(await model.updateFromClawHub(github) == .failed("github isn't tracked on ClawHub."))
        #expect(recorder.calls.isEmpty, "invalid requests aren't sent")
        await model.search("   ")
        #expect(recorder.calls.isEmpty && model.searchResults.isEmpty && model.searchedQuery == nil, "blank searches aren't sent")
    }

    // MARK: Demo Gateway end to end

    @MainActor
    static func demoSkills() -> (SkillsModel, DemoGateway) {
        let demo = DemoGateway()
        let model = SkillsModel(scopes: { [] }, allowsWritesWithoutAdmin: true,
                                request: { method, params in try await demo.handle(method, params) })
        return (model, demo)
    }

    @Test func demoSeedsCoverEveryState() throws {
        let skills = DemoGateway.seedSkills().compactMap(SkillStatusEntry.init)
        #expect(skills.count >= 6)
        let states = Set(skills.map(\.state))
        #expect(states == Set(SkillState.allCases))
        #expect(skills.contains { !$0.missing.bins.isEmpty && !$0.install.isEmpty }, "a missing binary with an installer")
        #expect(skills.contains { !$0.missing.env.isEmpty && $0.primaryEnv != nil }, "a missing API key")
        #expect(skills.contains { !$0.missing.config.isEmpty }, "missing config")
        #expect(skills.contains { $0.platformIncompatible }, "another OS")
        #expect(skills.contains { $0.blockedByAllowlist } && skills.contains { $0.disabled })
        #expect(Set(skills.map(\.sourceKind)).isSuperset(of: [.bundled, .workspace, .managed, .clawhub]))
        for skill in skills {
            #expect(skill.eligible == (!skill.disabled && !skill.blockedByAllowlist && skill.missing.isEmpty), "\(skill.name) eligible")
            #expect(skill.platformIncompatible == !skill.missing.os.isEmpty, "\(skill.name) platformIncompatible")
        }
        let catalog = DemoGateway.seedClawHubCatalog().compactMap(ClawHubSearchResult.init)
        #expect(catalog.count >= 4 && catalog.contains(where: \.installOnly))
        let states2 = catalog.map { Skills.installState(for: $0, in: skills) }
        #expect(states2.contains { if case .updateAvailable = $0 { true } else { false } }, "a ClawHub skill has an update")
        #expect(states2.contains(.notInstalled))
        #expect(states2.filter { $0.label != nil }.count >= 2, "ClawHub results include installed skills")

        let effective = EffectiveTools(DemoGateway.seedEffectiveTools(agentId: "main"))
        #expect(Set(effective.groups.map(\.source)).isSuperset(of: [.core, .plugin, .mcp]) && !effective.notices.isEmpty)
        let inspection = ToolsInspection.build(catalog: ToolCatalog(DemoGateway.seedToolCatalog(agentId: "main")), effective: effective)
        #expect(inspection.allowedCount > 0 && inspection.allowedCount < inspection.totalCount, "mixed allowed and denied")
        #expect(inspection.allTools.contains { $0.reasons == ["Denied by tools.deny"] })
        #expect(inspection.allTools.contains { $0.reasons == ["Not in profile 'coding'"] })
    }

    @MainActor @Test func demoBrowseInstallAndUpdate() async throws {
        let (model, _) = Self.demoSkills()
        await model.load(agentId: nil)
        #expect(model.loadError == nil && model.skills.count >= 6)
        #expect(model.sections().map(\.state) == [.ready, .needsSetup, .blocked, .disabled])

        // Gateway installer: github's missing gh goes away.
        let github = try #require(model.skill(key: "github"))
        #expect(github.state == .needsSetup && github.primaryReason == "Missing binary: gh")
        let ran = await model.runInstaller(skill: github, option: try #require(github.install.first))
        #expect(ran != .failed(ran.message) && model.skill(key: "github")?.state == .ready)

        // Enable/disable round trip.
        #expect(await model.setEnabled(try #require(model.skill(key: "slack")), true) == .done("Enabled slack"))
        #expect(model.skill(key: "slack")?.state == .ready)
        _ = await model.setEnabled(try #require(model.skill(key: "weather")), false)
        let weather = try #require(model.skill(key: "weather"))
        #expect(weather.state == .disabled)
        #expect(!weather.eligible, "upstream: eligible = !disabled && !blockedByAllowlist && requirements met")

        // API key: write-only, shown as set.
        let notion = try #require(model.skill(key: "notion"))
        #expect(!notion.apiKeyIsSet && notion.state == .needsSetup)
        _ = await model.setApiKey(notion, "ntn_demo")
        #expect(model.skill(key: "notion")?.apiKeyIsSet == true && model.skill(key: "notion")?.state == .ready)

        // ClawHub search → install → shows as installed.
        await model.search("home")
        let ha = try #require(model.searchResults.first { $0.slug == "home-assistant" })
        #expect(model.installState(for: ha) == .notInstalled)
        #expect(await model.installFromClawHub(ha) == .done("Installed Home Assistant 2.4.1"))
        #expect(model.installState(for: ha) == .installed(version: "2.4.1"))
        #expect(model.skill(key: "home-assistant")?.sourceKind == .clawhub)
        let again = await model.installFromClawHub(ha)
        #expect(again != .done(again.message), "installing twice without force fails")

        // Update available → update.
        await model.search("nas")
        let nas = try #require(model.searchResults.first { $0.slug == "nas-report" })
        guard case .updateAvailable = model.installState(for: nas) else {
            Issue.record("nas-report should have an update, got \(model.installState(for: nas))")
            return
        }
        let updated = await model.updateFromClawHub(try #require(model.skill(key: "nas-report")))
        #expect(updated == .done("Updated nas-report to \(nas.version ?? "")"))
        #expect(model.installState(for: nas) == .installed(version: nas.version))
        #expect(await model.updateFromClawHub(try #require(model.skill(key: "nas-report"))) == .done("nas-report is up to date"))

        // Locally modified → force required → force.
        let grocery = try #require(model.skill(key: "grocery-list"))
        let blocked = await model.updateFromClawHub(grocery)
        guard case .forceRequired = blocked else {
            Issue.record("grocery-list should need force, got \(blocked)")
            return
        }
        #expect(model.actionError == nil, "a force prompt isn't an error banner")
        let forced = await model.updateFromClawHub(grocery, force: true)
        #expect(forced == .done("Updated grocery-list to 1.0.0"))

        // Details: reviewable results work, install-only ones are refused.
        let detail = try await model.detail(nas.installRef)
        #expect(detail.latestVersion == nas.version && detail.slug == "nas-report")
        await model.search("obsidian")
        let external = try #require(model.searchResults.first)
        #expect(external.installOnly)
        await #expect(throws: GatewayError.self) { try await model.detail(external.installRef) }
    }

    @MainActor @Test func demoToolsInspector() async throws {
        let demo = DemoGateway()
        let request: ToolsInspectorModel.Request = { method, params in try await demo.handle(method, params) }
        let chat = ToolsInspectorModel(scope: .session(key: "agent:main:main", agentId: "main"), request: request)
        await chat.load()
        let inspection = try #require(chat.inspection)
        #expect(chat.error == nil && inspection.isLive && inspection.profile == "coding" && chat.effectiveNote == nil)
        #expect(inspection.summary.hasPrefix("Profile: coding · "))
        #expect(inspection.allTools.contains { $0.source == .mcp } && !inspection.notices.isEmpty)

        let agent = ToolsInspectorModel(scope: .agent("research", sessionKey: nil), request: request)
        await agent.load()
        #expect(agent.inspection?.isLive == false && agent.effectiveNote != nil)

        let missing = ToolsInspectorModel(scope: .session(key: "agent:main:gone", agentId: "main"), request: request)
        await missing.load()
        #expect(missing.inspection?.isLive == false && missing.effectiveNote?.contains("unknown session key") == true,
                "a stale chat falls back to the catalog with a note")

        let unsupported = ToolsInspectorModel(scope: .session(key: "agent:main:main", agentId: "main"), methods: { ["agents.list"] }, request: request)
        await unsupported.load()
        #expect(unsupported.inspection == nil && unsupported.error == ToolsPolicy.unsupportedMessage)
    }
}
