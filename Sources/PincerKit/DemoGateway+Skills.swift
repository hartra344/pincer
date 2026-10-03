import Foundation

/// The demo's skills and tool policy (`skills.status/search/detail/install/update`,
/// `tools.catalog/effective`), shaped like the Gateway's replies. The seed data lives in
/// DemoSkillsSeed.swift; edits live in memory for the session.
///
/// Demo-only keys on seed entries: skills may carry `locallyModified: true` (a ClawHub update
/// then needs `force`); ClawHub catalog entries may carry `description`, `emoji`, `homepage`,
/// `primaryEnv`, `requirements`, `missing`, `install`, `changelog`, `tags`, `isOfficial`, `os`,
/// `createdAt`, used for details and to build the entry an install adds.
extension DemoGateway {
    static let skillMethods = [
        "skills.status", "skills.search", "skills.detail", "skills.install", "skills.update",
        "tools.catalog", "tools.effective",
    ]
    static let managedSkillsDir = "\(DemoGateway.agentStateDir)/skills"

    func handleSkills(_ method: String, _ params: JSONValue) throws -> JSONValue? {
        guard Self.skillMethods.contains(method) else { return nil }
        switch method {
        case "skills.status":
            try Self.checkKeys(method, params, ["agentId", "sessionKey"])
            let agentId = try self.skillsAgentId(params)
            if let key = params["sessionKey"]?.text, !self.hasSession(key) {
                throw Self.skillsInvalid("Session not found.")
            }
            return ["workspaceDir": .string(self.workspaceDir(agentId)), "managedSkillsDir": .string(Self.managedSkillsDir),
                    "agentId": .string(agentId), "skills": .array(self.skillEntries.map(Self.publicSkill))]
        case "skills.search":
            try Self.checkKeys(method, params, ["query", "limit"])
            return ["results": .array(self.searchClawHub(params["query"]?.text, limit: params["limit"]?.int ?? 20))]
        case "skills.detail":
            try Self.checkKeys(method, params, ["slug", "version"])
            guard let ref = params["slug"]?.text else { throw Self.skillsInvalid("invalid skills.detail params: must have required property 'slug'") }
            let rawVersion = params["version"]
            if let rawVersion, rawVersion.string == nil || rawVersion.string?.isEmpty == true {
                throw Self.skillsInvalid("invalid skills.detail params: version must be a non-empty string")
            }
            guard let entry = self.catalogEntry(ref) else {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "ClawHub skill \"\(ref)\" not found", details: nil)
            }
            if entry["installOnly"]?.bool == true {
                throw Self.skillsInvalid("ClawHub cannot return details for \(ref); external skill sources are install-only. Install it directly, or run \"openclaw skills install \(ref)\".")
            }
            return Self.detail(entry, selectedVersion: rawVersion?.text ?? entry["version"]?.text)
        case "skills.install":
            return try self.installSkill(params)
        case "skills.update":
            return try self.updateSkill(params)
        case "tools.catalog":
            try Self.checkKeys(method, params, ["agentId", "includePlugins"])
            let agentId = try self.skillsAgentId(params)
            var catalog = Self.seedToolCatalog(agentId: agentId)
            if params["includePlugins"]?.bool == false, let groups = catalog["groups"]?.array {
                catalog = Self.setting(catalog, "groups", .array(groups.filter { $0["source"]?.text != "plugin" }))
            }
            return catalog
        case "tools.effective":
            try Self.checkKeys(method, params, ["agentId", "sessionKey"])
            guard let key = params["sessionKey"]?.text else {
                throw Self.skillsInvalid("invalid tools.effective params: must have required property 'sessionKey'")
            }
            guard self.hasSession(key) else { throw Self.skillsInvalid("unknown session key \"\(key)\"") }
            let sessionAgent = self.sessionAgentId(key)
            if let requested = params["agentId"]?.text, requested != sessionAgent {
                throw Self.skillsInvalid("agent id \"\(requested)\" does not match session agent \"\(sessionAgent)\"")
            }
            return self.mcpEffective(Self.seedEffectiveTools(agentId: sessionAgent))
        default:
            return nil
        }
    }

    // MARK: skills.install

    private func installSkill(_ params: JSONValue) throws -> JSONValue {
        let source = params["source"]?.text
        if source == "clawhub" {
            try Self.checkKeys("skills.install", params, ["agentId", "source", "slug", "version", "force", "timeoutMs"])
            _ = try self.skillsAgentId(params)
            guard let ref = params["slug"]?.text else { throw Self.skillsInvalid("invalid skills.install params: must have required property 'slug'") }
            guard let entry = self.catalogEntry(ref), let slug = entry["slug"]?.text else {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "ClawHub skill \"\(ref)\" not found", details: nil)
            }
            let version = params["version"]?.text ?? entry["version"]?.text ?? "1.0.0"
            if let index = self.skillIndex(clawhubSlug: slug) {
                guard params["force"]?.bool == true else {
                    throw GatewayError.rpc(code: "UNAVAILABLE", message: "Skill \(slug) is already installed. Use update to change versions.", details: nil)
                }
                self.skillEntries.remove(at: index)
            }
            self.skillEntries.append(self.installedEntry(from: entry, version: version))
            var response: [String: JSONValue] = [
                "ok": true, "message": .string("Installed \(slug)@\(version)"), "stdout": "", "stderr": "", "code": 0,
                "slug": .string(slug), "version": .string(version), "targetDir": .string("\(self.workspaceDir("main"))/skills/\(slug)"),
            ]
            // Like the Gateway's ClawHub trust check, an unscanned skill installs with a warning.
            if entry["trustState"]?.text == "not-scanned-by-clawhub" {
                response["warning"] = .string("ClawHub hasn't scanned \(slug)@\(version). Review its SKILL.md before using it.")
            }
            return .object(response)
        }
        if source != nil { throw Self.skillsInvalid("invalid skills.install params: unsupported source \"\(source ?? "")\"") }
        try Self.checkKeys("skills.install", params, ["agentId", "name", "installId", "dangerouslyForceUnsafeInstall", "timeoutMs"])
        _ = try self.skillsAgentId(params)
        guard let name = params["name"]?.text, let installId = params["installId"]?.text else {
            throw Self.skillsInvalid("invalid skills.install params: must have required property 'name' and 'installId'")
        }
        guard let index = self.skillEntries.firstIndex(where: { $0["name"]?.text == name }) else {
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "Skill not found: \(name)", details: nil)
        }
        let entry = self.skillEntries[index]
        guard let option = entry["install"]?.array?.first(where: { $0["id"]?.text == installId }) else {
            throw GatewayError.rpc(code: "UNAVAILABLE", message: "Installer not found: \(installId)", details: nil)
        }
        let bins = Set(option["bins"]?.array?.compactMap(\.text) ?? [])
        var missing = entry["missing"]?.object ?? [:]
        missing["bins"] = .array((missing["bins"]?.array ?? []).filter { !bins.contains($0.text ?? "") })
        if let anyBins = missing["anyBins"]?.array, anyBins.contains(where: { bins.contains($0.text ?? "") }) { missing["anyBins"] = [] }
        self.skillEntries[index] = Self.recomputed(Self.setting(entry, "missing", .object(missing)))
        let label = option["label"]?.text ?? installId
        return ["ok": true, "message": .string("Installed"), "stdout": .string("==> \(label)\n"), "stderr": "", "code": 0]
    }

    // MARK: skills.update

    private func updateSkill(_ params: JSONValue) throws -> JSONValue {
        if params["source"] != nil {
            try Self.checkKeys("skills.update", params, ["agentId", "source", "slug", "all", "force"])
            guard params["source"]?.text == "clawhub" else { throw Self.skillsInvalid("invalid skills.update params: unsupported source") }
            _ = try self.skillsAgentId(params)
            let slug = params["slug"]?.text
            let all = params["all"]?.bool == true
            if slug == nil, !all { throw Self.skillsInvalid("clawhub skills.update requires \"slug\" or \"all\"") }
            if slug != nil, all { throw Self.skillsInvalid("clawhub skills.update accepts either \"slug\" or \"all\", not both") }
            let force = params["force"]?.bool == true
            let indices = self.skillEntries.indices.filter { index in
                guard let linked = self.skillEntries[index]["clawhub"]?["slug"]?.text else { return false }
                return all || linked == slug
            }
            if let slug, indices.isEmpty {
                let result: JSONValue = ["ok": false, "error": .string("Skill \(slug) is not tracked from ClawHub.")]
                throw GatewayError.rpc(code: "UNAVAILABLE", message: "Skill \(slug) is not tracked from ClawHub.", details: ["results": [result]])
            }
            var results: [JSONValue] = []
            var failures: [String] = []
            for index in indices {
                let entry = self.skillEntries[index]
                let linked = entry["clawhub"]?["slug"]?.text ?? ""
                let previous = entry["clawhub"]?["installedVersion"]?.text
                let latest = self.catalogEntry(linked)?["version"]?.text ?? previous ?? "1.0.0"
                if entry["locallyModified"]?.bool == true, !force {
                    let error = "Skill \(linked) has local changes since it was installed. Updating replaces the installed skill directory."
                    results.append(["ok": false, "code": .string(Self.forceRequiredCode), "error": .string(error), "version": .string(latest)])
                    failures.append(error)
                    continue
                }
                var link = entry["clawhub"]?.object ?? [:]
                link["installedVersion"] = .string(latest)
                link["installedAt"] = Self.now()
                var updated = Self.setting(entry, "clawhub", .object(link))
                updated = Self.setting(updated, "locallyModified", .null)
                self.skillEntries[index] = updated
                results.append(["ok": true, "slug": .string(linked), "previousVersion": previous.map(JSONValue.string) ?? .null,
                                "version": .string(latest), "changed": .bool(previous != latest),
                                "targetDir": .string("\(self.workspaceDir("main"))/skills/\(linked)")])
            }
            if !failures.isEmpty {
                throw GatewayError.rpc(code: "UNAVAILABLE", message: failures.joined(separator: "; "), details: ["results": .array(results)])
            }
            return ["ok": true, "skillKey": .string(slug ?? "*"), "config": ["source": "clawhub", "results": .array(results)]]
        }
        try Self.checkKeys("skills.update", params, ["skillKey", "enabled", "apiKey", "env"])
        guard let key = params["skillKey"]?.text else { throw Self.skillsInvalid("invalid skills.update params: must have required property 'skillKey'") }
        var config: [String: JSONValue] = [:]
        if let index = self.skillEntries.firstIndex(where: { $0["skillKey"]?.text == key }) {
            var entry = self.skillEntries[index]
            var missingEnv = entry["missing"]?["env"]?.array?.compactMap(\.text) ?? []
            let requiredEnv = entry["requirements"]?["env"]?.array?.compactMap(\.text) ?? []
            if let enabled = params["enabled"]?.bool {
                entry = Self.setting(entry, "disabled", .bool(!enabled))
                config["enabled"] = .bool(enabled)
            }
            if let apiKey = params["apiKey"]?.string, let env = entry["primaryEnv"]?.text {
                if apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                    if requiredEnv.contains(env), !missingEnv.contains(env) { missingEnv.append(env) }
                } else {
                    missingEnv.removeAll { $0 == env }
                    config["apiKey"] = "__OPENCLAW_REDACTED__"
                }
            }
            if let env = params["env"]?.object {
                var redacted: [String: JSONValue] = [:]
                for (name, value) in env {
                    if value.string?.isEmpty == false {
                        missingEnv.removeAll { $0 == name }
                        redacted[name] = "__OPENCLAW_REDACTED__"
                    } else if requiredEnv.contains(name), !missingEnv.contains(name) {
                        missingEnv.append(name)
                    }
                }
                config["env"] = .object(redacted)
            }
            var missing = entry["missing"]?.object ?? [:]
            missing["env"] = .array(missingEnv.map(JSONValue.string))
            self.skillEntries[index] = Self.recomputed(Self.setting(entry, "missing", .object(missing)))
        }
        return ["ok": true, "skillKey": .string(key), "config": .object(config)]
    }

    // MARK: Helpers

    private func skillsAgentId(_ params: JSONValue) throws -> String {
        guard let raw = params["agentId"]?.text else { return "main" }
        guard self.agents.contains(where: { $0["id"]?.text == raw }) else { throw Self.skillsInvalid("unknown agent id \"\(raw)\"") }
        return raw
    }

    private func sessionAgentId(_ key: String) -> String {
        if key.hasPrefix("agent:") { return key.split(separator: ":").dropFirst().first.map(String.init) ?? "main" }
        return "main"
    }

    private func skillIndex(clawhubSlug slug: String) -> Int? {
        self.skillEntries.firstIndex { $0["clawhub"]?["slug"]?.text == slug }
    }

    /// A catalog entry by install ref (`@owner/slug`) or bare slug.
    private func catalogEntry(_ ref: String) -> JSONValue? {
        let bare = ref.split(separator: "/").last.map(String.init) ?? ref
        return self.clawHubCatalog.first { $0["installRef"]?.text == ref }
            ?? self.clawHubCatalog.first { $0["slug"]?.text == ref || $0["slug"]?.text == bare }
    }

    private func searchClawHub(_ query: String?, limit: Int) -> [JSONValue] {
        let terms = (query ?? "").lowercased().split(separator: " ").map(String.init)
        let scored: [(Double, JSONValue)] = self.clawHubCatalog.compactMap { entry in
            let haystack = [entry["slug"]?.text, entry["displayName"]?.text, entry["summary"]?.text, entry["ownerHandle"]?.text]
                .compactMap(\.self).joined(separator: " ").lowercased()
            guard terms.allSatisfy(haystack.contains) else { return nil }
            let base = entry["score"]?.double ?? 1
            let bonus = terms.contains { entry["slug"]?.text?.lowercased().contains($0) == true } ? 1.0 : 0
            return (base + bonus, entry)
        }
        let keys = ["slug", "registry", "ownerHandle", "installRef", "installOnly", "trustState", "displayName", "summary", "icon", "version", "updatedAt"]
        return scored.sorted { $0.0 > $1.0 }.prefix(max(1, min(limit, 100))).map { score, entry in
            var result: [String: JSONValue] = ["score": .number(score)]
            for key in keys { if let value = entry[key], !value.isNull { result[key] = value } }
            result["registry"] = result["registry"] ?? "clawhub"
            result["installRef"] = result["installRef"] ?? entry["slug"] ?? ""
            return .object(result)
        }
    }

    private static func detail(_ entry: JSONValue, selectedVersion: String?) -> JSONValue {
        let updatedAt = entry["updatedAt"] ?? Self.now()
        var skill: [String: JSONValue] = ["slug": entry["slug"] ?? "", "displayName": entry["displayName"] ?? entry["slug"] ?? "",
                                          "createdAt": entry["createdAt"] ?? updatedAt, "updatedAt": updatedAt]
        for key in ["summary", "icon", "tags", "isOfficial"] { if let value = entry[key] { skill[key] = value } }
        var result: [String: JSONValue] = ["skill": .object(skill)]
        if let version = entry["version"] {
            var latest: [String: JSONValue] = ["version": version, "createdAt": updatedAt]
            if let changelog = entry["changelog"] { latest["changelog"] = changelog }
            result["latestVersion"] = .object(latest)
            result["selectedRelease"] = selectedVersion == version.text ? .object(latest) : .null
        }
        if let os = entry["os"] { result["metadata"] = ["os": os] }
        result["owner"] = ["handle": entry["ownerHandle"] ?? .null, "displayName": entry["ownerName"] ?? entry["ownerHandle"] ?? .null,
                           "isOfficial": entry["isOfficial"] ?? false]
        return .object(result)
    }

    /// The status entry a ClawHub install adds (into the default agent's workspace).
    private func installedEntry(from entry: JSONValue, version: String) -> JSONValue {
        let slug = entry["slug"]?.text ?? "skill"
        let dir = "\(self.workspaceDir("main"))/skills/\(slug)"
        let empty: JSONValue = ["bins": [], "anyBins": [], "env": [], "config": [], "os": []]
        var object: [String: JSONValue] = [
            "name": .string(slug), "description": entry["description"] ?? entry["summary"] ?? "",
            "source": "openclaw-workspace", "bundled": false, "filePath": .string("\(dir)/SKILL.md"), "baseDir": .string(dir),
            "skillKey": .string(slug), "always": false, "disabled": false, "blockedByAllowlist": false,
            "blockedByAgentFilter": false, "eligible": true, "platformIncompatible": false, "modelVisible": true,
            "userInvocable": true, "commandVisible": true,
            "requirements": entry["requirements"] ?? empty, "missing": entry["missing"] ?? empty,
            "configChecks": [], "install": entry["install"] ?? [],
            "clawhub": ["status": "linked", "valid": true, "registry": entry["registry"] ?? "clawhub", "slug": .string(slug),
                        "ownerHandle": entry["ownerHandle"] ?? .null, "installedVersion": .string(version), "installedAt": Self.now(),
                        "originPath": .string("\(dir)/.clawhub/origin.json"), "lockPath": .string("\(self.workspaceDir("main"))/.clawhub/lock.json")],
        ]
        for key in ["emoji", "homepage", "primaryEnv"] { if let value = entry[key] { object[key] = value } }
        return Self.recomputed(.object(object))
    }

    /// Recomputes `eligible` as the Gateway does on the next status read:
    /// not disabled, not blocked by the bundled allowlist, and every requirement met.
    private static func recomputed(_ entry: JSONValue) -> JSONValue {
        let missing = entry["missing"]
        let unmet = ["bins", "anyBins", "env", "config", "os"].contains { !(missing?[$0]?.array ?? []).isEmpty }
        let eligible = !unmet && entry["platformIncompatible"]?.bool != true
            && entry["disabled"]?.bool != true && entry["blockedByAllowlist"]?.bool != true
        return Self.setting(entry, "eligible", .bool(eligible))
    }

    /// The entry as `skills.status` reports it (without demo-only keys).
    private static func publicSkill(_ entry: JSONValue) -> JSONValue {
        guard var object = entry.object else { return entry }
        object["locallyModified"] = nil
        return .object(object)
    }

    /// Sets `key` (`.null` removes it).
    static func setting(_ value: JSONValue, _ key: String, _ newValue: JSONValue) -> JSONValue {
        guard var object = value.object else { return value }
        object[key] = newValue.isNull ? nil : newValue
        return .object(object)
    }

    private static let forceRequiredCode = "force_required"

    private static func checkKeys(_ method: String, _ params: JSONValue, _ allowed: Set<String>) throws {
        guard let object = params.object else { return }
        if let extra = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Self.skillsInvalid("invalid \(method) params: must NOT have additional properties (\(extra))")
        }
    }

    private static func skillsInvalid(_ message: String) -> GatewayError {
        GatewayError.rpc(code: "INVALID_REQUEST", message: message, details: nil)
    }
}
