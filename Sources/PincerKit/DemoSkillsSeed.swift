import Foundation

/// Seed data for the demo's skills browser and tools inspector, in the Gateway's wire shapes
/// (`skills.status` entries, a ClawHub catalog, `tools.catalog` and `tools.effective` results).
/// Mirrors `mock-gateway/skills.mjs`; the handlers live in DemoGateway+Skills.swift (see there for
/// the demo-only keys). Owned by the tester; keep the four `seed…` signatures.
extension DemoGateway {
    static let clawHubRegistry = "https://clawhub.ai"
    static let bundledSkillsDir = "/opt/homebrew/lib/node_modules/openclaw/skills"

    private static func seedRequirementLists(_ values: [String: [String]]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: ["bins", "anyBins", "env", "config", "os"].map { key in
            (key, JSONValue.array((values[key] ?? []).map(JSONValue.string)))
        }))
    }

    // MARK: skills.status

    /// One `skills.status` entry per state: ready (bundled, workspace), missing a binary (with a
    /// brew installer; `summarize` is the managed one the setup wizard flags), missing an env var, missing config, other-OS only, disabled,
    /// blocked by the bundled allowlist, and two ClawHub-tracked skills behind the registry
    /// (`grocery-list` was edited locally, so updating it needs `force`).
    static func seedSkills() -> [JSONValue] {
        let now = Self.now().double ?? 0
        let day = 86_400_000.0
        let workspace = Self.defaultWorkspace("main")
        return [
            Self.seedSkill("weather", "Get current weather and forecasts (no API key required).", source: "openclaw-bundled",
                           emoji: "🌤️", homepage: "https://wttr.in/:help", requirements: ["bins": ["curl"]]),
            Self.seedSkill("github", "Interact with GitHub using the gh CLI: issues, pull requests, and CI runs.",
                           source: "openclaw-bundled", emoji: "🐙", homepage: "https://cli.github.com",
                           requirements: ["bins": ["gh"]], missing: ["bins": ["gh"]],
                           install: [["id": "brew", "kind": "brew", "label": "Install GitHub CLI (brew)", "bins": ["gh"]]]),
            Self.seedSkill("video-frames", "Extract frames or short clips from videos using ffmpeg.", source: "openclaw-bundled",
                           emoji: "🎞️", homepage: "https://ffmpeg.org", requirements: ["bins": ["ffmpeg"]],
                           missing: ["bins": ["ffmpeg"]],
                           install: [["id": "brew", "kind": "brew", "label": "Install ffmpeg (brew)", "bins": ["ffmpeg"]]]),
            Self.seedSkill("notion", "Notion API for creating and managing pages, databases, and blocks.", source: "openclaw-bundled",
                           emoji: "📝", homepage: "https://developers.notion.com", primaryEnv: "NOTION_API_KEY",
                           requirements: ["env": ["NOTION_API_KEY"]], missing: ["env": ["NOTION_API_KEY"]]),
            Self.seedSkill("voice-call", "Start voice calls through the voice-call plugin.", source: "openclaw-bundled", emoji: "📞",
                           requirements: ["config": ["plugins.entries.voice-call.enabled"]],
                           missing: ["config": ["plugins.entries.voice-call.enabled"]],
                           configChecks: [["path": "plugins.entries.voice-call.enabled", "satisfied": false]]),
            Self.seedSkill("apple-notes", "Manage Apple Notes from the terminal on macOS.", source: "openclaw-bundled", emoji: "🍎",
                           requirements: ["os": ["darwin"]]),
            Self.seedSkill("apt-updates", "Check for and apply Debian/Ubuntu package updates.", source: "openclaw-bundled", emoji: "📦",
                           requirements: ["bins": ["apt-get"], "os": ["linux"]], missing: ["bins": ["apt-get"], "os": ["linux"]]),
            Self.seedSkill("slack", "Control Slack from OpenClaw: react, pin, and send messages.", source: "openclaw-bundled",
                           emoji: "💬", requirements: ["config": ["channels.slack"]],
                           configChecks: [["path": "channels.slack", "satisfied": true]], disabled: true),
            Self.seedSkill("openai-image-gen", "Batch-generate images with the OpenAI Images API.", source: "openclaw-bundled",
                           emoji: "🖼️", primaryEnv: "OPENAI_API_KEY", requirements: ["env": ["OPENAI_API_KEY"]],
                           blockedByAllowlist: true),
            // The setup wizard's (and the docs') "summarize is missing its CLI".
            Self.seedSkill("summarize", "Summarize or transcribe URLs, videos, podcasts, PDFs, and local files.",
                           source: "openclaw-managed", emoji: "🧾", requirements: ["bins": ["summarize"]],
                           missing: ["bins": ["summarize"]],
                           install: [["id": "brew", "kind": "brew", "label": "Install summarize (brew)", "bins": ["summarize"]]]),
            Self.seedSkill("homelab-runbook", "Runbooks for the home lab: NAS, Raspberry Pis, and backups.",
                           source: "openclaw-workspace", emoji: "🏠"),
            Self.seedSkill("nas-report", "Summarize Synology NAS health: disks, volumes, and scrubs.", source: "openclaw-workspace",
                           emoji: "🗄️", requirements: ["bins": ["ssh"]],
                           clawhub: Self.seedClawHubLink("nas-report", owner: "clawdia", version: "1.2.0",
                                                         installedAt: now - 30 * day, workspace: workspace)),
            Self.seedSkill("grocery-list", "Keep a shared grocery list in Apple Reminders.", source: "openclaw-workspace",
                           emoji: "🛒", requirements: ["os": ["darwin"]],
                           clawhub: Self.seedClawHubLink("grocery-list", owner: "clawdia", version: "0.9.0",
                                                         installedAt: now - 60 * day, workspace: workspace),
                           locallyModified: true),
        ]
    }

    private static func seedSkill(
        _ name: String, _ description: String, source: String, emoji: String? = nil, homepage: String? = nil,
        primaryEnv: String? = nil, requirements: [String: [String]] = [:], missing: [String: [String]] = [:],
        configChecks: [JSONValue] = [], install: [JSONValue] = [], disabled: Bool = false, blockedByAllowlist: Bool = false,
        clawhub: JSONValue? = nil, locallyModified: Bool = false
    ) -> JSONValue {
        let baseDir = switch source {
        case "openclaw-bundled": "\(Self.bundledSkillsDir)/\(name)"
        case "openclaw-managed": "\(Self.managedSkillsDir)/\(name)"
        default: "\(Self.defaultWorkspace("main"))/skills/\(name)"
        }
        let satisfied = missing.values.allSatisfy(\.isEmpty)
        let eligible = !disabled && !blockedByAllowlist && satisfied
        var object: [String: JSONValue] = [
            "name": .string(name), "description": .string(description), "source": .string(source),
            "bundled": .bool(source == "openclaw-bundled"), "filePath": .string("\(baseDir)/SKILL.md"), "baseDir": .string(baseDir),
            "skillKey": .string(name), "always": false, "disabled": .bool(disabled), "blockedByAllowlist": .bool(blockedByAllowlist),
            "blockedByAgentFilter": false, "eligible": .bool(eligible),
            "platformIncompatible": .bool(!(missing["os"] ?? []).isEmpty), "modelVisible": .bool(eligible),
            "userInvocable": true, "commandVisible": .bool(eligible),
            "requirements": Self.seedRequirementLists(requirements), "missing": Self.seedRequirementLists(missing),
            "configChecks": .array(configChecks), "install": .array(install),
        ]
        if let emoji { object["emoji"] = .string(emoji) }
        if let homepage { object["homepage"] = .string(homepage) }
        if let primaryEnv { object["primaryEnv"] = .string(primaryEnv) }
        if let clawhub { object["clawhub"] = clawhub }
        if locallyModified { object["locallyModified"] = true }
        return .object(object)
    }

    private static func seedClawHubLink(_ slug: String, owner: String, version: String, installedAt: Double,
                                        workspace: String) -> JSONValue {
        ["status": "linked", "valid": true, "registry": .string(Self.clawHubRegistry), "slug": .string(slug),
         "ownerHandle": .string(owner), "installedVersion": .string(version), "installedAt": .number(installedAt.rounded()),
         "originPath": .string("\(workspace)/skills/\(slug)/.clawhub/origin.json"),
         "lockPath": .string("\(workspace)/.clawhub/lock.json")]
    }

    // MARK: ClawHub

    /// The canned ClawHub registry: search-result fields plus what details and installs need.
    /// `nas-report` and `grocery-list` are newer than the installed copies; `obsidian-daily` is a
    /// skills.sh result that can only be installed, not reviewed.
    static func seedClawHubCatalog() -> [JSONValue] {
        let now = Self.now().double ?? 0
        let day = 86_400_000.0
        func entry(_ slug: String, owner: String, ownerName: String, name: String, summary: String, version: String,
                   score: Double, created: Double, updated: Double, emoji: String, changelog: String? = nil,
                   official: Bool = false, os: [String]? = nil, primaryEnv: String? = nil,
                   requirements: [String: [String]] = [:], missing: [String: [String]] = [:]) -> JSONValue {
            var object: [String: JSONValue] = [
                "slug": .string(slug), "registry": .string(Self.clawHubRegistry), "ownerHandle": .string(owner),
                "ownerName": .string(ownerName), "installRef": .string("@\(owner)/\(slug)"), "displayName": .string(name),
                "summary": .string(summary), "description": .string(summary), "version": .string(version), "score": .number(score),
                "createdAt": .number((now - created * day).rounded()), "updatedAt": .number((now - updated * day).rounded()),
                "tags": ["latest": .string(version)], "isOfficial": .bool(official), "emoji": .string(emoji),
                "requirements": Self.seedRequirementLists(requirements), "missing": Self.seedRequirementLists(missing),
            ]
            if let changelog { object["changelog"] = .string(changelog) }
            if let os { object["os"] = .array(os.map(JSONValue.string)) }
            if let primaryEnv { object["primaryEnv"] = .string(primaryEnv) }
            return .object(object)
        }
        var obsidian = entry("obsidian-daily", owner: "vaultsmith", ownerName: "Vaultsmith", name: "Obsidian Daily Notes",
                             summary: "Append to today's Obsidian daily note.", version: "0.3.2", score: 0.6,
                             created: 50, updated: 3, emoji: "🪨")
        obsidian = Self.setting(obsidian, "installRef", "skills-sh:vaultsmith/obsidian-skills/obsidian-daily")
        obsidian = Self.setting(obsidian, "installOnly", true)
        obsidian = Self.setting(obsidian, "trustState", "not-scanned-by-clawhub")
        return [
            entry("nas-report", owner: "clawdia", ownerName: "Clawdia", name: "NAS Report",
                  summary: "Summarize Synology NAS health: disks, volumes, and scrubs.", version: "1.3.0", score: 0.9,
                  created: 200, updated: 2, emoji: "🗄️", changelog: "Adds Btrfs scrub history and SMART warnings as a table.",
                  requirements: ["bins": ["ssh"]]),
            entry("grocery-list", owner: "clawdia", ownerName: "Clawdia", name: "Grocery List",
                  summary: "Keep a shared grocery list in Apple Reminders.", version: "1.0.0", score: 0.7,
                  created: 300, updated: 10, emoji: "🛒", changelog: "Groups items by aisle.", os: ["darwin"],
                  requirements: ["os": ["darwin"]]),
            entry("home-assistant", owner: "openclaw", ownerName: "OpenClaw", name: "Home Assistant",
                  summary: "Control lights, climate, and scenes through the Home Assistant REST API.", version: "2.4.1",
                  score: 0.95, created: 400, updated: 5, emoji: "🏡", changelog: "Supports areas and floors.", official: true,
                  primaryEnv: "HASS_TOKEN", requirements: ["env": ["HASS_TOKEN"]], missing: ["env": ["HASS_TOKEN"]]),
            entry("plex-now-playing", owner: "mediafan", ownerName: "Media Fan", name: "Plex Now Playing",
                  summary: "See what's playing on your Plex server and who is watching.", version: "0.6.0", score: 0.8,
                  created: 90, updated: 20, emoji: "🎬", requirements: ["bins": ["curl"]]),
            entry("pi-fleet", owner: "pilab", ownerName: "Pi Lab", name: "Pi Fleet",
                  summary: "Check uptime, temperature, and disk on a fleet of Raspberry Pis over SSH.", version: "1.1.0",
                  score: 0.75, created: 150, updated: 40, emoji: "🥧", os: ["darwin", "linux"], requirements: ["bins": ["ssh"]]),
            obsidian,
        ]
    }

    // MARK: Tools

    private struct SeedTool {
        var id: String
        var description: String
        var profiles: [String]
    }

    /// A slice of upstream `CORE_TOOL_DEFINITIONS`, by section (id, label, tools).
    private static let seedCoreTools: [(id: String, label: String, tools: [SeedTool])] = [
        ("fs", "Files", [SeedTool(id: "read", description: "Read file contents", profiles: ["coding"]),
                         SeedTool(id: "write", description: "Create or overwrite files", profiles: ["coding"]),
                         SeedTool(id: "edit", description: "Make precise edits", profiles: ["coding"]),
                         SeedTool(id: "apply_patch", description: "Patch files", profiles: ["coding"])]),
        ("runtime", "Runtime", [SeedTool(id: "exec", description: "Run shell commands", profiles: ["coding"]),
                                SeedTool(id: "process", description: "Manage background processes", profiles: ["coding"]),
                                SeedTool(id: "code_execution", description: "Run sandboxed remote analysis", profiles: ["coding"])]),
        ("web", "Web", [SeedTool(id: "web_search", description: "Search the web", profiles: ["coding"]),
                        SeedTool(id: "web_fetch", description: "Fetch web content", profiles: ["coding"]),
                        SeedTool(id: "x_search", description: "Search X posts", profiles: ["coding"])]),
        ("memory", "Memory", [SeedTool(id: "memory_search", description: "Semantic search", profiles: ["coding"]),
                              SeedTool(id: "memory_get", description: "Read memory files", profiles: ["coding"])]),
        ("sessions", "Sessions", [
            SeedTool(id: "sessions_list", description: "List sessions", profiles: ["coding", "messaging"]),
            SeedTool(id: "sessions_history", description: "Read session history", profiles: ["coding", "messaging"]),
            SeedTool(id: "sessions_send", description: "Send to another session", profiles: ["coding", "messaging"]),
            SeedTool(id: "sessions_spawn", description: "Spawn a sub-agent session", profiles: ["coding", "messaging"]),
            SeedTool(id: "session_status", description: "Session status and usage", profiles: ["minimal", "coding", "messaging"]),
        ]),
        ("ui", "UI", [SeedTool(id: "browser", description: "Control web browser", profiles: []),
                      SeedTool(id: "canvas", description: "Present and edit canvases", profiles: [])]),
        ("messaging", "Messaging", [SeedTool(id: "message", description: "Send messages and channel actions", profiles: ["messaging"])]),
        ("automation", "Automation", [SeedTool(id: "cron", description: "Schedule jobs and reminders", profiles: ["coding"]),
                                      SeedTool(id: "gateway", description: "Gateway control", profiles: [])]),
        ("nodes", "Nodes", [SeedTool(id: "nodes", description: "Paired nodes: camera, screen, location, notify", profiles: [])]),
        ("media", "Media", [SeedTool(id: "image", description: "Understand images", profiles: ["coding"])]),
    ]

    private struct SeedPluginTool {
        var pluginId: String
        var label: String
        var id: String
        var description: String
        var optional: Bool
        var risk: String
    }

    private static let seedPluginTools = [
        SeedPluginTool(pluginId: "voice-call", label: "Voice Call", id: "voice_call",
                       description: "Place and control phone calls", optional: true, risk: "high"),
        SeedPluginTool(pluginId: "lobster", label: "Lobster", id: "lobster",
                       description: "Run typed workflow pipelines with resumable approvals", optional: false, risk: "medium"),
    ]
    /// MCP tools: (server, tool, description, risk).
    private static let seedMCPTools: [(server: String, tool: String, description: String, risk: String?)] = [
        ("home-assistant", "get_state", "Read the state of a Home Assistant entity", nil),
        ("home-assistant", "call_service", "Call a Home Assistant service", "medium"),
    ]

    private struct SeedToolPolicy {
        var profile: String
        var profileSource: String
        var deny: [String] = []
        var denySource = "tools.deny"
        var allow: [String]?
        var allowSource = ""
        var alsoAllowPath: String?
        var plugins: [String] = []
        var mcp = false
    }

    /// `main`: coding profile + a deny list, a plugin, MCP tools and two notices; `research`: an
    /// explicit allowlist; `coder`: the full profile.
    private static func seedToolPolicy(_ agentId: String) -> SeedToolPolicy {
        switch agentId {
        case "main":
            SeedToolPolicy(profile: "coding", profileSource: "tools.profile", deny: ["x_search", "code_execution"],
                           alsoAllowPath: "tools.alsoAllow", plugins: ["lobster"], mcp: true)
        case "research":
            SeedToolPolicy(profile: "coding", profileSource: "tools.profile",
                           allow: ["read", "web_search", "web_fetch", "memory_search", "memory_get", "sessions_list", "session_status"],
                           allowSource: "agents.entries.research.tools.allow",
                           alsoAllowPath: "agents.entries.research.tools.alsoAllow")
        case "coder":
            SeedToolPolicy(profile: "full", profileSource: "agents.entries.coder.tools.profile",
                           plugins: ["lobster", "voice-call"], mcp: true)
        default:
            SeedToolPolicy(profile: "coding", profileSource: "tools.profile")
        }
    }

    static func seedToolCatalog(agentId: String) -> JSONValue {
        var groups: [JSONValue] = Self.seedCoreTools.map { section in
            ["id": .string(section.id), "label": .string(section.label), "source": "core",
             "tools": .array(section.tools.map { tool in
                 ["id": .string(tool.id), "label": .string(tool.id), "description": .string(tool.description), "source": "core",
                  "defaultProfiles": .array(tool.profiles.map(JSONValue.string))]
             })]
        }
        for plugin in Self.seedPluginTools {
            var entry: [String: JSONValue] = ["id": .string(plugin.id), "label": .string(plugin.id),
                                              "description": .string(plugin.description), "source": "plugin",
                                              "pluginId": .string(plugin.pluginId), "risk": .string(plugin.risk),
                                              "defaultProfiles": []]
            if plugin.optional { entry["optional"] = true }
            groups.append(["id": .string("plugin:\(plugin.pluginId)"), "label": .string(plugin.label), "source": "plugin",
                           "pluginId": .string(plugin.pluginId), "tools": [.object(entry)]])
        }
        return ["agentId": .string(agentId),
                "profiles": [["id": "minimal", "label": "Minimal"], ["id": "coding", "label": "Coding"],
                             ["id": "messaging", "label": "Messaging"], ["id": "full", "label": "Full"]],
                "groups": .array(groups)]
    }

    static func seedEffectiveTools(agentId: String) -> JSONValue {
        let policy = Self.seedToolPolicy(agentId)
        var access: [JSONValue] = []
        var core: [JSONValue] = []
        for tool in Self.seedCoreTools.flatMap(\.tools) {
            var reasons: [JSONValue] = []
            if policy.profile != "full", !tool.profiles.contains(policy.profile) {
                reasons.append(["kind": "profile", "label": .string("\(policy.profile) profile"),
                                "source": .string(policy.profileSource), "profile": .string(policy.profile)])
            }
            if policy.deny.contains(tool.id) {
                reasons.append(["kind": "deny", "label": .string("Denied by \(policy.denySource)"), "source": .string(policy.denySource)])
            }
            if let allow = policy.allow, !allow.contains(tool.id) {
                reasons.append(["kind": "allowlist", "label": .string("Not included in \(policy.allowSource)"),
                                "source": .string(policy.allowSource)])
            }
            if reasons.isEmpty {
                core.append(["id": .string(tool.id), "label": .string(tool.id), "description": .string(tool.description),
                             "rawDescription": .string(tool.description), "source": "core"])
                access.append(["id": .string(tool.id), "status": "available", "reasons": []])
            } else {
                var entry: [String: JSONValue] = ["id": .string(tool.id), "status": "excluded", "reasons": .array(reasons)]
                if reasons.count == 1, reasons[0]["kind"]?.string == "profile", let path = policy.alsoAllowPath {
                    entry["alsoAllowPath"] = .string(path)
                }
                access.append(.object(entry))
            }
        }
        var groups: [JSONValue] = [["id": "core", "label": "Built-in tools", "source": "core", "tools": .array(core)]]
        let plugins: [JSONValue] = Self.seedPluginTools.filter { policy.plugins.contains($0.pluginId) }.map { plugin in
            ["id": .string(plugin.id), "label": .string(plugin.id), "description": .string(plugin.description),
             "rawDescription": .string(plugin.description), "source": "plugin", "pluginId": .string(plugin.pluginId),
             "risk": .string(plugin.risk)]
        }
        if !plugins.isEmpty { groups.append(["id": "plugin", "label": "Plugin tools", "source": "plugin", "tools": .array(plugins)]) }
        if policy.mcp {
            let tools: [JSONValue] = Self.seedMCPTools.map { tool in
                var entry: [String: JSONValue] = [
                    "id": .string("\(tool.server)__\(tool.tool)"), "label": .string(tool.tool),
                    "description": .string(tool.description), "rawDescription": .string(tool.description), "source": "mcp",
                    "mcpServer": .string(tool.server), "mcpToolName": .string(tool.tool),
                ]
                if let risk = tool.risk { entry["risk"] = .string(risk) }
                return .object(entry)
            }
            groups.append(["id": "mcp", "label": "MCP tools", "source": "mcp", "tools": .array(tools)])
        }
        for group in groups.dropFirst() {
            for tool in group["tools"]?.array ?? [] {
                access.append(["id": tool["id"] ?? "", "status": "available", "reasons": []])
            }
        }
        var notices: [JSONValue] = []
        if policy.profile != "full" {
            notices.append(["id": "browser-filtered-by-profile", "severity": "info",
                            "message": "Browser is configured, but the current tool profile does not include the browser tool. Add tools.alsoAllow: [\"browser\"] or agents.entries.*.tools.alsoAllow: [\"browser\"]; tools.subagents.tools.allow alone cannot add it back after profile filtering."])
        }
        if agentId == "main" {
            notices.append(["id": "mcp-not-yet-connected", "severity": "warning",
                            "message": "Some MCP servers have not connected yet; their tools are not listed.",
                            "servers": ["paperless"]])
        }
        var result: [String: JSONValue] = [
            "agentId": .string(agentId), "profile": .string(policy.profile), "groups": .array(groups),
            "toolAccess": ["checked": "live-session",
                           "profiles": [["profile": .string(policy.profile), "source": .string(policy.profileSource), "active": true]],
                           "tools": .array(access)],
        ]
        if !notices.isEmpty { result["notices"] = .array(notices) }
        return .object(result)
    }
}
